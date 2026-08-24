;;; nelisp-process-adapter.el --- standard-name process API + ONE poll loop -*- lexical-binding: t; -*-
;;
;; Doc 184 P1-P3.  Builds directly on the native `nelisp-process-*'
;; builtins (Doc 184 S1.1, real spawn/pipe/poll/wait, not a stub) and on
;; `nelisp-async-core' (Doc 184 P0, the actor/generator-free timer
;; queue), closing the measured gaps in the prelude's own partial
;; standard-name adapter (`scripts/nelisp-stdlib-prelude.el', Doc 184
;; S1.2/S1.3):
;;
;;   - `make-process' silently dropped `:filter' -- fixed, `:filter' is
;;     stored and actually invoked as bytes arrive;
;;   - `process-filter'/`set-process-filter'/`process-sentinel'/
;;     `set-process-sentinel' did not exist -- added, over the same
;;     `process-put'/`process-get' plist the prelude already used for
;;     `:name'/`:sentinel'/`:stderr';
;;   - `accept-process-output' ignored PROCESS/SECONDS/MILLISEC/
;;     JUST-THIS-ONE and unconditionally drained + blocking-waited every
;;     pending process, then invoked the sentinel with the literal string
;;     "finished\n" no matter what really happened -- fixed: it now
;;     narrows to PROCESS (or every live process when nil), bounds the
;;     wait via `nelisp-async-core''s deadline machinery, honours
;;     JUST-THIS-ONE, and formats the real Emacs-shaped sentinel status
;;     string (finished / exited abnormally with code N / a real signal
;;     name) from the native `nelisp-process-status'/`-exit-status'.
;;
;; This is the file Doc 184 S2 calls the new, minimal "Layer B": it does
;; NOT load `packages/nelisp-process/src/nelisp-process.el' (the richer,
;; generator-blocked adapter, S1.4) -- that file is unreachable standalone
;; and is reference-only for keyword semantics.  Loading THIS file
;; instead UPGRADES the prelude's standard names in place (the same
;; upgrade-on-load pattern `nelisp-async-core.el' already uses for
;; `run-at-time'/`cancel-timer'/`sit-for' -- no `unless (fboundp ...)'
;; guards below, these definitions are meant to replace the prelude's).
;;
;; ONE event loop (Doc 184 S2/S3.3): a poll-set registry of live
;; processes, each polled with a zero-timeout `nelisp-process-poll' (the
;; native primitive is non-blocking by construction -- Doc 184 S3.3), the
;; OUTER blocking behaviour supplied by this file's own bounded
;; poll-and-sleep cycle whose sleep quantum is capped by
;; `nelisp-async-core''s next timer deadline.  Three call sites share
;; that exact loop:
;;
;;   1. `accept-process-output' (explicit, this file);
;;   2. `nelisp--repl-idle-pump' (implicit, wired into the `--repl'
;;      blank-line read step by `nl_repl_loop' in
;;      `scripts/nelisp-standalone-build.el' -- the prelude ships a
;;      default no-op version of this hook so REPL sessions that never
;;      load this file see no behaviour change; loading this file
;;      upgrades it to a real bounded pump);
;;   3. `run-at-time' with REPEAT: upgraded (via `(require
;;      'nelisp-async-core)') to the real deferred/repeating
;;      implementation, fired by both of the above -- the SAME
;;      `nelisp-async-core--fire-due' call this file's own wait loop
;;      already makes.
;;
;; A batch script (`--load'/`--eval', no `--repl') that never calls
;; `accept-process-output' and this file sees exactly today's
;; behaviour: nothing pumps in the background, matching Emacs's own
;; batch-mode contract (Doc 184 S2).
;;
;; `make-network-process' was OUT of scope under Doc 184 (S1.7/P4: no
;; native socket primitive family existed yet).  Doc 194 P0-P2 replaces
;; that stub: `feat/socket-primitives-p1' shipped the six raw-fd
;; primitives this file's `make-network-process'/`open-network-stream'
;; (synchronous CLIENT path only -- no `:server'/`:nowait', Doc 194 P3+)
;; now build on directly, plus a pure-elisp DNS resolver (`/etc/hosts'
;; then DNS-over-TCP/53, Doc 194 S3.2) so a caller can pass a hostname,
;; not only a literal IPv4/`localhost'.  See docs/design/194-network-
;; process-adapter.org for the full design; this file is P0-P2's own
;; "measured, not asserted" implementation of that doc's S3.1/S3.2.
;;
;;; Code:

(require 'nelisp-async-core)

;; Native `nelisp-socket-*' primitives (Doc 184 follow-on / Doc 194 S1.1,
;; `feat/socket-primitives-p1', dispatch-table entries in `scripts/nelisp-
;; standalone-build.el', linux-x86_64 raw SYSCALL, catchable
;; `nelisp-unsupported-primitive' on every other target).  Declared, like
;; the native process primitives above, so `make compile' byte-compiles
;; this file cleanly; real and reachable at runtime in `target/nelisp'.
(declare-function nelisp-socket-listen "ext:nelisp-runtime" (host port))
(declare-function nelisp-socket-accept "ext:nelisp-runtime" (listen-fd))
(declare-function nelisp-socket-connect "ext:nelisp-runtime" (host port))
(declare-function nelisp-socket-send "ext:nelisp-runtime" (fd string))
(declare-function nelisp-socket-recv "ext:nelisp-runtime" (fd max-bytes))
(declare-function nelisp-socket-close "ext:nelisp-runtime" (fd))

;; Native `nelisp-process-*' primitives (Doc 184 S1.1, dispatch-table
;; entries in `scripts/nelisp-standalone-build.el', not elisp defuns
;; anywhere) and the prelude's own already-shipped process helpers
;; (`scripts/nelisp-stdlib-prelude.el', not on this file's compile
;; `-L' path).  Declared so `make compile' byte-compiles this file
;; cleanly; both are real and reachable at runtime in `target/nelisp'.
(declare-function nelisp-process-start "ext:nelisp-runtime" (program &rest args))
(declare-function nelisp-process-object-p "ext:nelisp-runtime" (obj))
(declare-function nelisp-process-poll "ext:nelisp-runtime" (proc))
(declare-function nelisp-process-read-output "ext:nelisp-runtime" (proc limit))
(declare-function nelisp-process-delete "ext:nelisp-runtime" (proc))
(declare-function nelisp-process-exit-status "ext:nelisp-runtime" (proc))
(declare-function executable-find "ext:nelisp-stdlib-prelude" (command &optional remote))
(declare-function process-get "ext:nelisp-stdlib-prelude" (process key))
(declare-function process-put "ext:nelisp-stdlib-prelude" (process key value))
(declare-function process-status "ext:nelisp-stdlib-prelude" (process))

;;; Poll-set registry ---------------------------------------------------

(defvar nelisp-process-adapter--live nil
  "Process objects created by this file's `make-process', not yet fully
drained + sentinel-fired.  Populated by `make-process'; pruned by
`delete-process' and by exit-detection inside the wait loop.")

(defconst nelisp-process-adapter--poll-quantum 0.02
  "Sleep granularity (seconds) between zero-timeout `nelisp-process-poll'
passes.  `nelisp-process-poll' (Doc 184 S1.1/S3.3) is a single
non-blocking `poll(2)' call, not a wait -- the outer blocking behaviour
`accept-process-output'/`nelisp--repl-idle-pump' need comes from this
file's own bounded poll-and-sleep cycle.  Small enough that output/exit
is noticed promptly; coarse enough to cost effectively nothing at rest.")

;;; Sentinel status strings (Doc 184 S1.3/S3.2) --------------------------
;; The native exit-status encoding (`nl_bi_process_decode_status',
;; scripts/nelisp-standalone-build.el) mirrors POSIX wait-status: a
;; normal exit is the plain 0-127 code; a signal-terminated process is
;; 128+SIGNUM.  Verified against host Emacs 30.1 (`signal-process' +
;; `process-sentinel', this doc's own working notes): SIGTERM(15) ->
;; "terminated\n", SIGKILL(9) -> "killed\n".  This substrate's
;; `delete-process'/`kill-process' send SIGTERM (native
;; `nl_bi_process_delete_object' hardcodes signal 15, out of this
;; adapter's scope to change), so a process killed through this API
;; honestly reports "terminated\n", not "killed\n" -- the fix this file
;; ships is READING THE REAL STATUS at all (S1.3's defect: every exit,
;; regardless of cause, was reported as the literal string "finished\n"),
;; not hardcoding a different single wrong string in its place.

(defun nelisp-process-adapter--signal-name (code)
  "Return the lowercase Emacs-style name for signal (CODE - 128).
CODE is the native exit-status integer already known to encode a signal
termination (>= 128, per the decode convention above)."
  (let ((sig (- code 128)))
    (cond
     ((= sig 1) "hangup")
     ((= sig 2) "interrupt")
     ((= sig 3) "quit")
     ((= sig 4) "illegal instruction")
     ((= sig 6) "abort")
     ((= sig 8) "arithmetic error")
     ((= sig 9) "killed")
     ((= sig 11) "segmentation fault")
     ((= sig 13) "broken pipe")
     ((= sig 14) "alarm clock")
     ((= sig 15) "terminated")
     (t (format "signal %d" sig)))))

(defun nelisp-process-adapter--sentinel-message (proc)
  "Format PROC's real Emacs-shaped sentinel status string.
Reads the native `nelisp-process-exit-status' directly (not the
`process-exit-status' wrapper, whose `process-status' companion is not
reliable to read AFTER `delete-process' -- the native
`nl_bi_process_delete_object' always overwrites the status field to
\"deleted\" as its last step, even for a process that had already
exited normally; the exit-status field is not touched by delete and
stays the authoritative signal, per the decode convention above)."
  (let ((code (and (fboundp 'nelisp-process-exit-status)
                    (nelisp-process-exit-status proc))))
    (cond
     ((or (null code) (< code 0)) "finished\n")
     ((>= code 128) (concat (nelisp-process-adapter--signal-name code) "\n"))
     ((= code 0) "finished\n")
     (t (format "exited abnormally with code %d\n" code)))))

;;; make-process: real :filter -------------------------------------------

(defun make-process (&rest plist)
  "Doc 184 P1: standard-name `make-process', built directly on the native
`nelisp-process-*' primitives, with a real `:filter' slot the prelude's
own version (S1.2) silently dropped."
  (let* ((name (or (plist-get plist :name) "process"))
         (command (plist-get plist :command))
         (stderr-buffer (plist-get plist :stderr))
         (sentinel (plist-get plist :sentinel))
         (filter (plist-get plist :filter))
         (resolved (and command
                        (cons (or (executable-find (car command)) (car command))
                              (cdr command)))))
    (unless command (signal 'wrong-type-argument (list 'listp command)))
    (unless (fboundp 'nelisp-process-start)
      (signal 'error (list "make-process: no native process primitive (nelisp-process-start) in this runtime")))
    (let ((proc (apply #'nelisp-process-start resolved)))
      (process-put proc :name name)
      (process-put proc :sentinel sentinel)
      (process-put proc :stderr stderr-buffer)
      (process-put proc :filter filter)
      (process-put proc :adapter-sentinel-fired nil)
      (setq nelisp-process-adapter--live (cons proc nelisp-process-adapter--live))
      proc)))

(defun nelisp-make-process (&rest plist)
  (apply #'make-process plist))

;;; Filter / sentinel accessors (Doc 184 P1) ------------------------------

(defun process-filter (process)
  "Return PROCESS's filter function, or nil if none is set."
  (process-get process :filter))

(defun set-process-filter (process filter)
  "Set PROCESS's filter function to FILTER (a function of PROC and CHUNK)."
  (process-put process :filter filter)
  filter)

(defun process-sentinel (process)
  "Return PROCESS's sentinel function, or nil if none is set."
  (process-get process :sentinel))

(defun set-process-sentinel (process sentinel)
  "Set PROCESS's sentinel function to SENTINEL (a function of PROC and
the status-change STRING, Emacs's own three-shape contract -- see
`nelisp-process-adapter--sentinel-message')."
  (process-put process :sentinel sentinel)
  sentinel)

;;; delete-process: prune the registry, fire a real sentinel ------------

(defun delete-process (&optional process)
  "Doc 184 P2 (native subprocess) + Doc 194 P0 (`network-process'): kill/
reap PROCESS, prune it from the poll-set registry, and -- if it was
still live -- fire its sentinel with the real status string exactly
once, mirroring Emacs's own synchronous `delete-process' -> sentinel
behaviour (measured against host Emacs 30.1 in both docs: a live
process's sentinel fires with the real status string as part of the
same call, not on some later tick).  PROCESS defaults to nil (Emacs's
own \"current buffer's process\" default is not modelled -- this
runtime's buffer/process association is out of scope; nil here is
simply a no-op, not an error)."
  (cond
   ((and process (nelisp--network-process-p process))
    (nelisp--network-process-delete process))
   ((and process (fboundp 'nelisp-process-object-p) (nelisp-process-object-p process))
    (let ((was-running (eq (and (fboundp 'process-status) (process-status process)) 'run))
          (already-fired (process-get process :adapter-sentinel-fired)))
      (when (fboundp 'nelisp-process-delete) (nelisp-process-delete process))
      (setq nelisp-process-adapter--live (delq process nelisp-process-adapter--live))
      (when (and was-running (not already-fired))
        (process-put process :adapter-sentinel-fired t)
        (let ((sentinel (process-get process :sentinel)))
          (when sentinel
            (funcall sentinel process (nelisp-process-adapter--sentinel-message process))))))))
  nil)

(defun kill-process (&optional process _current-group)
  (delete-process process))

;;; The ONE poll loop (Doc 184 S2/S3.3) -----------------------------------

(defun nelisp-process-adapter--drain-and-fire (proc)
  "One zero-timeout poll pass over PROC: dispatch any new output to its
filter, and -- on first-observed exit -- fire its sentinel with the
real status string and prune PROC from the live registry.
Returns non-nil iff real output BYTES were delivered (matching Emacs's
own `accept-process-output' contract, measured against host Emacs
30.1: a status-only change with no output produces a nil return; only
actual bytes produce t).

Doc 194 P0: `make-network-process' adds its `network-process' objects to
this SAME shared `nelisp-process-adapter--live' registry (Doc 194 S3.1's
own design), but P0's connect path is purely synchronous -- there is no
async filter-driven read/accept wiring yet (that is Doc 194 P3/P4's
`nelisp-socket-poll'/nonblocking-accept work, explicitly not this pass).
The native `nelisp-process-poll' this function otherwise calls assumes
the OTHER tagged-vector shape (a fixed-offset native process object) and
does not know this one, so a network process is guarded out here rather
than handed to it -- it just sits inert in the registry until
`delete-process' removes it.  This is a minimal type-dispatch SAFETY
guard so a caller that also uses ordinary subprocesses cannot crash the
shared loop by mixing the two process shapes; it is not Doc 194 P3/P4's
real nonblocking wiring, which still has its own S3.3 branch to add
here once built."
  (if (nelisp--network-process-p proc)
      nil
    (let* ((ev (nelisp-process-poll proc))
           (ready (aref ev 0))
           (exited (aref ev 1))
           (got-bytes nil)
           (filter (process-get proc :filter)))
      (when (= ready 1)
        (let ((chunk (nelisp-process-read-output proc 65536)))
          (when (and chunk (> (length chunk) 0))
            (setq got-bytes t)
            (when filter (funcall filter proc chunk)))))
      (when (and (= exited 1) (not (process-get proc :adapter-sentinel-fired)))
        ;; A process can exit with a final chunk still sitting in the pipe;
        ;; drain once more before declaring it done.
        (let ((chunk (nelisp-process-read-output proc 65536)))
          (when (and chunk (> (length chunk) 0))
            (setq got-bytes t)
            (when filter (funcall filter proc chunk))))
        (process-put proc :adapter-sentinel-fired t)
        (setq nelisp-process-adapter--live (delq proc nelisp-process-adapter--live))
        (let ((sentinel (process-get proc :sentinel)))
          (when sentinel
            (funcall sentinel proc (nelisp-process-adapter--sentinel-message proc)))))
      got-bytes)))

(defun nelisp-process-adapter--pump-once (targets stop-after-first)
  "One non-blocking pass over TARGETS.  Returns non-nil iff any target
delivered real output bytes.  When STOP-AFTER-FIRST is non-nil, stops
polling the remaining targets as soon as one has (Doc 184 S1.3's
measured defect: the old `accept-process-output' drained *every*
pending process unconditionally; this is the fix)."
  (let ((any nil))
    (catch 'nelisp-process-adapter--pump-done
      (dolist (p targets)
        (when (nelisp-process-adapter--drain-and-fire p)
          (setq any t)
          (when stop-after-first (throw 'nelisp-process-adapter--pump-done nil)))))
    any))

(defun nelisp-process-adapter--sleep-gap (next-timer-deadline wait-deadline)
  "Bound this pass's sleep by the poll quantum, the next timer deadline,
and the caller's own wait deadline -- whichever is soonest."
  (let ((now (nelisp-async-core--now))
        (gap nelisp-process-adapter--poll-quantum))
    (when next-timer-deadline (setq gap (min gap (max 0.0 (- next-timer-deadline now)))))
    (when wait-deadline (setq gap (min gap (max 0.0 (- wait-deadline now)))))
    (max gap 0.0)))

(defun nelisp-process-adapter--wait (process seconds millisec just-this-one)
  "The shared wait loop behind `accept-process-output'/
`nelisp--repl-idle-pump' (Doc 184 S2/S3.3).  PROCESS narrows polling to
one process; nil polls every live process.  SECONDS/MILLISEC bound the
wait (both nil = wait indefinitely, matching Emacs).  JUST-THIS-ONE, if
an integer, also suspends firing due timers during the wait (Emacs's
own documented JUST-THIS-ONE nuance); any other non-nil value still
narrows polling to the first ready target (already this loop's default
behaviour -- Doc 184 S1.3's fix).  Returns non-nil iff real output was
received before the deadline."
  (let* ((skip-timers (integerp just-this-one))
         ;; nil TARGETS (no PROCESS given, nothing registered) is legal and
         ;; common -- e.g. a caller waiting purely for a timer to fire
         ;; (Doc 184's own "run-at-time REPEAT through the SAME loop"
         ;; claim: this wait loop still fires due timers with an empty
         ;; poll set).  Only a non-nil PROCESS ever makes TARGETS non-nil.
         (targets (if process (list process) nelisp-process-adapter--live))
         (have-timeout (or (numberp seconds) (numberp millisec)))
         (timeout-secs (and have-timeout
                            (+ (if (numberp seconds) seconds 0)
                               (/ (if (numberp millisec) millisec 0) 1000.0))))
         (deadline (and timeout-secs (+ (nelisp-async-core--now) timeout-secs)))
         (got nil))
    (unless skip-timers (nelisp-async-core--fire-due (nelisp-async-core--now)))
    (catch 'nelisp-process-adapter--wait-done
      (while t
        (when (nelisp-process-adapter--pump-once targets t)
          (setq got t)
          (throw 'nelisp-process-adapter--wait-done nil))
        (when (and deadline (>= (nelisp-async-core--now) deadline))
          (throw 'nelisp-process-adapter--wait-done nil))
        (when (and process
                   (not (eq (and (fboundp 'process-status) (process-status process)) 'run))
                   (process-get process :adapter-sentinel-fired))
          ;; PROCESS is dead and fully drained -- nothing more will
          ;; ever arrive, so stop instead of spinning to the deadline.
          (throw 'nelisp-process-adapter--wait-done nil))
        (unless skip-timers (nelisp-async-core--fire-due (nelisp-async-core--now)))
        (let ((nd (and (not skip-timers) (nelisp-async-core--next-deadline))))
          (when (and (null deadline) (null targets) (null nd))
            ;; Nothing to poll, no timer armed, no timeout given: waiting
            ;; longer can never produce anything.  Stop instead of hanging
            ;; forever.
            (throw 'nelisp-process-adapter--wait-done nil))
          (nelisp-async-core--nanosleep (nelisp-process-adapter--sleep-gap nd deadline)))))
    got))

(defun accept-process-output (&optional process seconds millisec just-this-one)
  "Doc 184 P2: standard-name `accept-process-output' that actually reads
PROCESS/SECONDS/MILLISEC/JUST-THIS-ONE, closing S1.3's measured defect
(the prelude's own version read none of them, via `&rest _args', and
unconditionally blocking-waited + drained every pending process)."
  (nelisp-process-adapter--wait process seconds millisec just-this-one))

;;; REPL idle pump (Doc 184 P3) --------------------------------------------
;; Wired into `--repl''s blank-line read step by `nl_repl_loop'
;; (scripts/nelisp-standalone-build.el).  The prelude ships a default
;; no-op version of this hook (`scripts/nelisp-stdlib-prelude.el') so a
;; REPL session that never loads this file sees no behaviour change --
;; matching Emacs's own batch-mode contract of not pumping outside an
;; explicit wait.  Loading this file upgrades the hook to a real bounded
;; pump, sharing the exact same wait loop `accept-process-output' uses.

(defun nelisp--repl-idle-pump ()
  "Fire due timers and poll every live process once, bounded to a small
fixed window, so a timer armed from the REPL or output from a
backgrounded process becomes visible between prompts without the user
calling `accept-process-output'/`sit-for' by hand."
  (nelisp-process-adapter--wait nil 0 50 nil)
  nil)

;;; network-process: a sibling tagged-vector shape (Doc 194 S3.1) --------
;; [0]='network-process  [1]=NAME  [2]=STATUS  [3]=FD  [4]=PROPS-ALIST
;;
;; A NEW, elisp-only shape, sibling to -- not sharing slots or
;; refresh/delete logic with -- the native `nelisp-process-object-p'
;; shape: that shape's own refresh/delete call `wait4'/`kill' on a PID
;; slot a socket fd does not have (Doc 194 S1.2/S2).  STATUS is a symbol
;; matching real Emacs's own contract (measured against real Emacs 30.1,
;; Doc 194 S1.3): `open' (connected) -> `closed' (peer closed / locally
;; deleted) or `failed'; `listen' for a `:server t' process's whole
;; lifetime (not built this pass, Doc 194 P5).  Never `run'/`exit' -- that
;; is the SUBPROCESS vocabulary and must never leak onto a network
;; process.  FD is the raw integer Phase 1's `nelisp-socket-*' primitives
;; operate on directly -- no wrapping/unwrapping needed at existing call
;; sites, unlike the native process shape's pid indirection.

(defun nelisp--make-network-process-object (name status fd)
  (vector 'network-process name status fd nil))

(defun nelisp--network-process-p (object)
  (and (vectorp object) (> (length object) 0)
       (eq (aref object 0) 'network-process)))

(defun nelisp--network-process-delete (proc)
  "Close PROC's fd (`nelisp-socket-close', Doc 194 S1.1), transition its
status to `closed', prune it from the poll-set registry, and -- if it
had not already transitioned away from `open'/`listen'/`connect' -- fire
its sentinel with the network-process-specific `closed\\n' status string.
Measured against real Emacs 30.1 (Doc 194 S1.3): a network process's
delete contract is a plain `closed\\n', NOT the subprocess family's
`finished'/`exited abnormally'/signal-name shapes
`nelisp-process-adapter--sentinel-message' formats -- this is a
DIFFERENT sentinel-string vocabulary, formatted independently here
rather than reusing that function, by design (Doc 194 S3.1)."
  (let ((fd (aref proc 3))
        (was-live (memq (aref proc 2) '(open listen connect))))
    (when (integerp fd) (ignore-errors (nelisp-socket-close fd)))
    (aset proc 2 'closed)
    (setq nelisp-process-adapter--live (delq proc nelisp-process-adapter--live))
    (when was-live
      (let ((sentinel (process-get proc :sentinel)))
        (when sentinel (funcall sentinel proc "closed\n")))))
  nil)

(defun process-contact (process &optional key _no-block)
  "Doc 194 S3.1: `process-contact', new -- Doc 184 never needed it
(subprocesses have no host/port).  Reads back the `:host'/`:service'
values `make-network-process' stored via `process-put' at construction
time.  Only the shape this phase actually populates is supported; a
non-`network-process' object always answers nil, matching Emacs's own
\"no contact info\" case for e.g. a pipe process."
  ;; No `keywordp' in this runtime's prelude -- any non-nil, non-`t' KEY
  ;; (Emacs's own `:host'/`:service'/etc. convention) is treated as "one
  ;; specific field", matching `process-get''s own untyped key lookup.
  (when (nelisp--network-process-p process)
    (cond
     ((and key (not (eq key t))) (process-get process key))
     (t (list (process-get process :host) (process-get process :service))))))

;;; Host resolution (Doc 194 S3.2) -----------------------------------------
;; Phase A (feat/socket-primitives-p1, unchanged): literal `localhost' and
;; IPv4 dotted-decimal, handled entirely inside `nelisp-socket-connect'/
;; -listen's own native `nl_socket_build_sockaddr'.  Phases B/C below run
;; BEFORE those primitives are ever called, so by the time a host string
;; reaches them it is always already Phase-A-shaped -- no native change,
;; no chicken-and-egg (the DNS resolver itself, Phase C, is addressed by
;; a numeric IPv4 literal, which Phase A already reaches directly).

(defun nelisp--ipv4-dotted-p (host)
  "Return non-nil if HOST is a plausible 4-octet dotted-decimal IPv4
literal.  Mirrors `nl_socket_build_sockaddr''s own native
`nl_ipv4_parse_dotted' accept grammar (Doc 194 S1.1) closely enough to
decide whether host RESOLUTION (Phase B/C below) is needed at all --
exact per-octet range/leading-zero validation is left to that native
parser, which still runs, unchanged, after this decision either way."
  (and (stringp host)
       (let ((parts (split-string host "\\." t)))
         (and (= (length parts) 4)
              (not (memq nil (mapcar (lambda (p) (string-match-p "\\`[0-9]+\\'" p)) parts)))))))

(defun nelisp--net-host-string (host)
  "Normalize the `:host' plist value HOST the way real Emacs's own
`make-network-process' does before resolution (measured Doc 194 S1.3):
nil or the symbol `local' both mean the loopback interface.  Anything
else must already be a string; the ACTUAL resolution -- literal passthrough,
`/etc/hosts', or DNS -- happens one level up, in `nelisp--resolve-host'."
  (cond
   ((or (null host) (eq host 'local)) "127.0.0.1")
   ((stringp host) host)
   (t (signal 'wrong-type-argument (list 'stringp host)))))

;; Phase B -- /etc/hosts, pure elisp, zero native change (Doc 194 S3.2).

(defvar nelisp--etc-hosts-file "/etc/hosts"
  "Path consulted by `nelisp--hosts-file-lookup' (Doc 194 P1).  A test can
let-bind this to a fixture file without touching the real system table.")

(defun nelisp--hosts-file-parse-line (line)
  "Return (HOSTNAME . IP) conses for each hostname/alias on LINE, or nil.
LINE is one physical /etc/hosts line: an address followed by one or more
whitespace-separated hostnames; `#' starts a trailing comment (POSIX
hosts(5)).  IPv6 lines parse the same way -- this phase's own IPv4-only
`nl_socket_build_sockaddr' (Doc 194 S1.1) just never matches their
address string later, so a mixed A/AAAA pair for one name still lets the
usable A entry through."
  (let* ((no-comment (car (split-string line "#")))
         (fields (split-string no-comment nil t)))
    (when (>= (length fields) 2)
      (let ((ip (car fields)))
        (mapcar (lambda (h) (cons h ip)) (cdr fields))))))

(defun nelisp--hosts-file-table (&optional file)
  "Parse FILE (default `nelisp--etc-hosts-file') into an alist of
\(HOSTNAME . \"A.B.C.D\"), first matching line wins per hostname --
matching POSIX/glibc `files' lookup order."
  (let ((path (or file nelisp--etc-hosts-file))
        (table nil))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (dolist (line (split-string (buffer-string) "\n"))
          (dolist (pair (nelisp--hosts-file-parse-line line))
            (unless (assoc (car pair) table) (push pair table))))))
    (nreverse table)))

(defun nelisp--hosts-file-lookup (name &optional file)
  "Return NAME's IPv4 address string from `/etc/hosts' (or FILE), or nil
if NAME is not listed there (Doc 194 P1)."
  (cdr (assoc name (nelisp--hosts-file-table file))))

(defun nelisp--resolve-host (host)
  "Return an IPv4 dotted-decimal string or \"localhost\" for HOST, ready
for `nelisp-socket-connect'/-listen (Doc 194 S3.2).  Fallback chain so
far: already-literal hosts (Phase A, feat/socket-primitives-p1,
unchanged) pass straight through; otherwise `/etc/hosts' (Phase B, this
commit).  Doc 194 P2 (DNS-over-TCP/53, Phase C) extends this function's
`cond' with one more clause, inserted before this fallback -- see that
phase's own commit.  Signals a catchable error when no phase resolves it
-- never a hang, never a wrong-address connect (Doc 194 P1 exit
criterion)."
  (cond
   ((or (equal host "localhost") (nelisp--ipv4-dotted-p host)) host)
   ((nelisp--hosts-file-lookup host))
   (t (signal 'error (list "unresolvable host (Doc 194 P2/DNS not yet loaded)" host)))))

;;; make-network-process / open-network-stream: the synchronous client
;;; path (Doc 194 P0) -------------------------------------------------------
;; `:host'+`:service', no `:server', no `:nowait': a direct, one-to-one
;; wrap of `nelisp-resolve-host'+`nelisp-socket-connect' that needs ZERO
;; poll-loop involvement (measured against real Emacs 30.1, Doc 194 S1.3:
;; a blocking connect completes synchronously inside `make-network-
;; process' itself, `process-status' reads `open' the instant it
;; returns, before any `accept-process-output' call).  `:server t'/
;; `:nowait' are Doc 194 P3-P5, not this pass -- asking for either
;; signals loudly rather than silently degrading to a blocking connect a
;; caller did not request.

(defun nelisp--network-process-signal-refused (plist err)
  "Translate a caught error ERR (`nelisp-socket-error' from a refused/
failed connect, or `nelisp-dns-error' from unresolvable host resolution)
into the `file-error' shape real Emacs signals synchronously from
`make-network-process' on a refused connect (measured Doc 194 S1.3):
\(file-error \"make client process failed\" ... :name :host :service
:family).  Exact message-string parity is not attempted (Doc 194 S6) --
this exists so the common `condition-case ((file-error) ...)' idiom
every existing `open-network-stream' caller already uses keeps working."
  (signal 'file-error
          (list "make client process failed"
                (format "%S" err)
                :name (plist-get plist :name)
                :host (plist-get plist :host)
                :service (plist-get plist :service)
                :family (or (plist-get plist :family) 'ipv4))))

(defun make-network-process (&rest plist)
  "Doc 194 P0: standard-name `make-network-process', the synchronous
CLIENT path built directly on `nelisp-socket-connect' plus `nelisp--
resolve-host' (Doc 194 S3.1/S3.2).  `:server'/`:nowait' are Doc 194
P3-P5, not yet supported here."
  (let* ((name (or (plist-get plist :name) "network"))
         (host (plist-get plist :host))
         (service (plist-get plist :service))
         (server (plist-get plist :server))
         (nowait (plist-get plist :nowait)))
    (cond
     (server
      (signal 'error (list "make-network-process: :server t is not yet supported (Doc 194 P5)")))
     (nowait
      (signal 'error (list "make-network-process: :nowait is not yet supported (Doc 194 P3/P4)")))
     (t
      (unless (integerp service) (signal 'wrong-type-argument (list 'integerp service)))
      (let* ((fd (condition-case err
                     (nelisp-socket-connect
                      (nelisp--resolve-host (nelisp--net-host-string host)) service)
                   (error (nelisp--network-process-signal-refused plist err))))
             (proc (nelisp--make-network-process-object name 'open fd)))
        (process-put proc :host host)
        (process-put proc :service service)
        (process-put proc :filter (plist-get plist :filter))
        (process-put proc :sentinel (plist-get plist :sentinel))
        (setq nelisp-process-adapter--live (cons proc nelisp-process-adapter--live))
        proc)))))

(defun process-send-string (process string)
  "Doc 194 P0: send STRING's raw bytes to PROCESS, a `network-process'
object, via `nelisp-socket-send' (Doc 194 S1.1: byte-clean, UTF-8
multibyte content included, no decode/re-encode pass).  Subprocesses
have no analog under THIS name in this runtime yet -- Doc 184's own
`nelisp-process-write' is that shape's separate entry point -- so
anything that is not a `network-process' signals `wrong-type-argument'
rather than silently doing nothing."
  (if (nelisp--network-process-p process)
      (nelisp-socket-send (aref process 3) string)
    (signal 'wrong-type-argument (list 'nelisp--network-process-p process))))

(defun open-network-stream (name buffer host service &rest parameters)
  "Doc 194 P0: `open-network-stream', a thin wrapper over
`make-network-process' with a positional signature (measured against
real Emacs 30.1, Doc 194 S1.3/S3.1's own documented reduction).  BUFFER
is accepted for signature compatibility but not otherwise used --
buffer/process association is out of this doc's scope, same as Doc
184's own precedent for subprocesses."
  (apply #'make-network-process :name name :buffer buffer
         :host host :service service parameters))

(provide 'nelisp-process-adapter)
;;; nelisp-process-adapter.el ends here
