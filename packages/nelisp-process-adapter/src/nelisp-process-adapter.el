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
;; `make-network-process' is explicitly OUT of scope (Doc 184 S1.7/P4:
;; no native socket primitive family exists yet, unlike processes) --
;; this file defines it anyway, to signal a clear, named error instead
;; of leaving it void-function or, worse, silently no-opping.
;;
;;; Code:

(require 'nelisp-async-core)

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
  "Doc 184 P2: kill/reap PROCESS via the native primitive, prune it from
the poll-set registry, and -- if it was still running -- fire its
sentinel with the real status string exactly once, mirroring Emacs's
own synchronous `delete-process' -> sentinel behaviour (measured
against host Emacs 30.1: a live process's sentinel fires with the real
status string as part of the same call, not on some later tick).
PROCESS defaults to nil (Emacs's own \"current buffer's process\"
default is not modelled -- this runtime's buffer/process association
is out of Doc 184's scope; nil here is simply a no-op, not an error)."
  (when (and process (fboundp 'nelisp-process-object-p) (nelisp-process-object-p process))
    (let ((was-running (eq (and (fboundp 'process-status) (process-status process)) 'run))
          (already-fired (process-get process :adapter-sentinel-fired)))
      (when (fboundp 'nelisp-process-delete) (nelisp-process-delete process))
      (setq nelisp-process-adapter--live (delq process nelisp-process-adapter--live))
      (when (and was-running (not already-fired))
        (process-put process :adapter-sentinel-fired t)
        (let ((sentinel (process-get process :sentinel)))
          (when sentinel
            (funcall sentinel process (nelisp-process-adapter--sentinel-message process)))))))
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
actual bytes produce t)."
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
    got-bytes))

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

;;; make-network-process: loud, not silent (Doc 184 S1.7/P4) --------------

(unless (fboundp 'make-network-process)
  (defun make-network-process (&rest _plist)
    "Doc 184 S1.7/P4: explicitly OUT OF SCOPE.  Unlike subprocesses
(S1.1), no native socket primitive family (`nelisp-network-*') exists
in this runtime yet -- only ad hoc `syscall-direct' socket/connect
calls (the standalone TLS smoke).  Signal a clear, named error instead
of leaving this void-function or silently returning a broken process
object; see docs/design/184-process-and-event-loop.org S1.7/S6 for what
a future doc would need before this can be built."
    (signal 'error
            (list (concat "make-network-process: unsupported in this standalone runtime -- "
                          "no native socket primitive family exists yet "
                          "(docs/design/184-process-and-event-loop.org S1.7/S6)")))))

(provide 'nelisp-process-adapter)
;;; nelisp-process-adapter.el ends here
