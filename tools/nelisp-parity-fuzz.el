;;; nelisp-parity-fuzz.el --- generative Emacs-vs-standalone differential -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; test/nelisp-shadow-differential-cases.el is a corpus I wrote by hand.  It
;; is a set of samples, not a search: every divergence it holds is one I
;; already knew to look for.  This is the search.
;;
;; The conditions for generative testing are unusually good here, which is
;; why it is worth building rather than writing more samples:
;;
;;   * the ORACLE is free and local -- stock Emacs, one subprocess;
;;   * the COMPARISON is total -- print both sides with `format "%S"' and
;;     compare bytes, no per-function expected values to maintain;
;;   * the DOMAIN is already enumerated -- docs/emacs-compat-table.txt lists
;;     every name both runtimes define.
;;
;; What it does NOT do is decide what a correct answer is.  It reports where
;; the two disagree; which one is right is still a reading job.  A generator
;; that answered that would be a second implementation of Emacs.
;;
;; Do not run this at the same time as a build.  It executes ./target/nelisp
;; continuously, and a concurrent `make standalone-reader' fails with "Text
;; file busy" relinking the binary out from under it.  That is not a build
;; defect; half an hour went into establishing which of the two it was.
;;
;; Usage:
;;   emacs --batch -Q -l tools/nelisp-parity-fuzz.el          # default budget
;;   NELISP_FUZZ_SEED=7 NELISP_FUZZ_CASES=4000 emacs --batch -Q -l ...
;;   NELISP_FUZZ_ONLY='^string-' ...                          # one family
;; or: make parity-fuzz

;;; Code:

(require 'cl-lib)

(defvar nelisp-parity-fuzz--root
  (or (getenv "NELISP_REPO_ROOT") default-directory))

(defvar nelisp-parity-fuzz--binary
  (expand-file-name "target/nelisp" nelisp-parity-fuzz--root))

(defvar nelisp-parity-fuzz--table
  (expand-file-name "docs/emacs-compat-table.txt" nelisp-parity-fuzz--root))

;; ---------------------------------------------------------------------------
;; Deterministic RNG.  `random' with a seed string is reproducible within one
;; Emacs version but not across them, and a fuzz report nobody can replay is
;; a bug report without a repro.  xorshift64* is fifteen lines and exact.
;; ---------------------------------------------------------------------------

(defvar nelisp-parity-fuzz--state 88172645463325252)

(defun nelisp-parity-fuzz--seed (n)
  (setq nelisp-parity-fuzz--state (if (zerop n) 88172645463325252 n)))

(defun nelisp-parity-fuzz--next ()
  "Next pseudo-random non-negative fixnum."
  (let ((x nelisp-parity-fuzz--state))
    (setq x (logxor x (ash x 13)))
    (setq x (logand x most-positive-fixnum))
    (setq x (logxor x (ash x -7)))
    (setq x (logxor x (ash x 17)))
    (setq x (logand x most-positive-fixnum))
    (setq nelisp-parity-fuzz--state x)
    x))

(defun nelisp-parity-fuzz--pick (seq)
  (nth (mod (nelisp-parity-fuzz--next) (length seq)) seq))

;; ---------------------------------------------------------------------------
;; Argument pool.  Each entry is a QUOTED FORM that both runtimes can read --
;; not a value, because the two sides are separate processes and the only
;; channel between them is source text.
;;
;; The pool is deliberately weighted toward the shapes that broke things on
;; 2026-08-19: an empty sequence, an improper list, a negative index, an
;; index past the end, a non-ASCII string, a float where an integer is
;; expected, and the wrong type entirely.  A uniform pool over "plausible"
;; values would have found none of them.
;; ---------------------------------------------------------------------------

(defconst nelisp-parity-fuzz--pool
  '(nil t 0 1 -1 2 7 -7 100 1.5 -1.5 0.0
    "" "a" "abc" "ABC" "aXbXc" " a b " "\t x \n"
    "\u00e9" "\u3042\u3044" "a.b*c" "[a-z]+"
    ?a ?A ?0 ?\s 12354
    'foo 'nil 't :key
    '(1 2 3) '(1) '() '("a" "b") '(1 . 2) '((a . 1) (b . 2))
    '(1 2 . 3)
    [] [1 2 3] ["a" "b"]
    (list 'quote 'sym)))

(defconst nelisp-parity-fuzz--skip
  ;; Names whose value is not a function of their arguments, or whose call
  ;; would end the process / touch the world.  Excluding them is not
  ;; "hiding a failure": a differential over these compares noise.
  '(;; time, environment, randomness
    current-time float-time current-time-string format-time-string random
    getenv setenv emacs-version emacs-pid system-name user-login-name
    ;; process / file / world
    load require provide kill-emacs delete-file write-region make-directory
    insert-file-contents find-file expand-file-name file-exists-p
    file-readable-p file-directory-p file-regular-p directory-files
    start-process call-process make-process accept-process-output
    delete-process kill-process sleep-for sit-for
    ;; interactive / display / buffer state
    message read-string read-from-minibuffer y-or-n-p
    insert erase-buffer current-buffer get-buffer-create set-buffer
    buffer-string buffer-substring point goto-char
    ;; control flow that a generated call cannot use meaningfully
    throw signal error quit exit-recursive-edit recursive-edit
    ;; identity is not stable across runtimes by design (Doc 22 A11/A20)
    make-symbol gensym cl-gensym sxhash sxhash-equal sxhash-eq sxhash-eql
    ;; mutators: the differential prints the RESULT, and an in-place
    ;; mutation's result is the least interesting half of what it did
    setcar setcdr aset puthash remhash clrhash sort nreverse nconc
    delete-dups nbutlast ntake))

(defun nelisp-parity-fuzz--names ()
  "Shared names from the compat table, minus the ones a differential cannot judge."
  (let ((names nil))
    (with-temp-buffer
      (insert-file-contents nelisp-parity-fuzz--table)
      (goto-char (point-min))
      (while (re-search-forward "^shared-\\(?:shadowing\\|deferring\\) +\\([^ ]+\\)" nil t)
        (let ((sym (intern (match-string 1))))
          (when (and (fboundp sym)
                     (not (memq sym nelisp-parity-fuzz--skip))
                     (not (macrop sym))
                     (not (special-form-p sym))
                     ;; a name that only exists as a variable here
                     (not (string-prefix-p "nelisp" (symbol-name sym))))
            (push sym names)))))
    (let ((only (getenv "NELISP_FUZZ_ONLY")))
      (when (and only (not (string-empty-p only)))
        (setq names (cl-remove-if-not
                     (lambda (s) (string-match-p only (symbol-name s))) names))))
    (sort (delete-dups names) #'string-lessp)))

(defvar nelisp-parity-fuzz--no-arity nil
  "Names whose arity could not be read, so no call was generated for them.")

(defun nelisp-parity-fuzz--note-unreadable-arity (sym why)
  "Record that no call was generated for SYM, and WHY.

A named recorder rather than a bare `push' so `make fallback-inventory' can
see that this handler records: it classifies by the function a handler
calls, which is how it tells a fallback that reports itself from one that
swallows.  Reported in the run summary."
  (push (cons sym why) nelisp-parity-fuzz--no-arity))

(defun nelisp-parity-fuzz--arity (sym)
  "Return (MIN . MAX) for SYM, MAX nil when &rest, or nil when unknown.

A name whose arity cannot be read is RECORDED, not just skipped.  Dropping
it silently shrinks the search and leaves the run reporting a name count it
did not actually cover -- the same thing the resume cap is careful about a
few lines down, and what `make fallback-inventory' flags a bare handler for."
  (condition-case err
      (let ((a (func-arity sym)))
        (or (and (consp a) (integerp (car a))
                 (cons (car a) (if (integerp (cdr a)) (cdr a) nil)))
            (progn (nelisp-parity-fuzz--note-unreadable-arity sym 'unusable-arity)
                   nil)))
    (error (nelisp-parity-fuzz--note-unreadable-arity sym err) nil)))

(defun nelisp-parity-fuzz--gen-call (sym)
  "Generate one quoted call form for SYM, or nil when its arity is unusable."
  (let* ((ar (nelisp-parity-fuzz--arity sym))
         (lo (and ar (car ar)))
         (hi (and ar (or (cdr ar) (max 2 (car ar))))))
    (when (and lo (<= lo 4))
      (let* ((n (+ lo (if (> hi lo) (mod (nelisp-parity-fuzz--next) (1+ (- (min hi 3) lo))) 0)))
             (args (cl-loop repeat n
                            collect (nelisp-parity-fuzz--pick nelisp-parity-fuzz--pool))))
        (cons sym args)))))

;; ---------------------------------------------------------------------------
;; Running one side.  Every case is wrapped so an error is a VALUE: a case
;; that signals in both runtimes with the same condition is agreement, and
;; the interesting failures are exactly the ones where one signals and the
;; other answers.
;; ---------------------------------------------------------------------------

;; Emacs's printer does NOT escape a tab or a newline inside a string, so
;; `prin1-to-string' of a case built from the pool entry with a tab in it
;; contains those characters literally.  Embedding that as a KEY broke the
;; one-line ##KEY<TAB>RESULT format from the inside: the key held a tab and
;; a newline, so the row matched on neither side and the whole tail of the
;; chunk read as unreported -- which the runner then attributed to an abort.
;; "47 cases NOT RUN, 0 aborts" came from that, and it also hid a real one:
;; calling a non-function does end the process, which is what stopped the
;; chunk in the first place.
;;
;; The prose lives here rather than in a docstring because it needs to quote
;; a string literal, and an unescaped quote inside a docstring ends it -- the
;; reader then reads the rest as code.  That is exactly how this function
;; failed with `void-variable (\t)' on its first run.
(defun nelisp-parity-fuzz--key (case)
  "Line-safe identity for CASE."
  (let* ((raw (prin1-to-string case))
         (i 0) (n (length raw)) (out ""))
    (while (< i n)
      (let ((c (aref raw i)))
        (setq out (concat out (cond ((eq c 9) "\\t")
                                    ((eq c 10) "\\n")
                                    ((eq c 13) "\\r")
                                    (t (char-to-string c))))))
      (setq i (1+ i)))
    out))

(defun nelisp-parity-fuzz--driver (cases)
  "Return driver source that prints one tab-separated line per case in CASES."
  (concat
   "(defun pfz--flat (s) (let ((i 0) (n (length s)) (o \"\")) (while (< i n) "
   "(let ((c (aref s i))) (setq o (concat o (cond ((eq c 10) \"\\\\n\") "
   "((eq c 13) \"\\\\r\") ((eq c 9) \"\\\\t\") (t (char-to-string c)))))) "
   "(setq i (1+ i))) o))\n"
   (mapconcat
    (lambda (c)
      (format "(princ \"##\")(princ %S)(princ \"\\t\")(princ (pfz--flat (condition-case e (format \"%%S\" %s) (error (format \"ERR %%S\" e)))))(princ \"\\n\")"
              (nelisp-parity-fuzz--key c) (prin1-to-string c)))
    cases "\n")
   "\n"))

(defun nelisp-parity-fuzz--run (cases)
  "Run CASES through Emacs and the standalone; return an alist of (CASE E . N)."
  (let* ((dir (expand-file-name "target" nelisp-parity-fuzz--root))
         (file (expand-file-name "parity-fuzz-driver.el" dir)))
    (make-directory dir t)
    (with-temp-file file (insert (nelisp-parity-fuzz--driver cases)))
    (let ((emacs-out (nelisp-parity-fuzz--capture
                      (list (expand-file-name invocation-name invocation-directory)
                            "--batch" "-Q" "-l" file)))
          (nelisp-out (nelisp-parity-fuzz--capture
                       (list nelisp-parity-fuzz--binary "--load" file))))
      (nelisp-parity-fuzz--zip cases emacs-out nelisp-out))))

(defconst nelisp-parity-fuzz--max-resumes 4
  "How many times one chunk may resume past an aborting call.")

(defvar nelisp-parity-fuzz--dropped 0
  "Cases a resume cap skipped; reported, never silently absorbed.")

(defun nelisp-parity-fuzz--run-recovering (cases)
  "Run CASES, resuming past any call that ends the standalone process.

A batch that aborts reports nothing after the abort point, so every later
case in it looks like a disagreement when in fact it was never run.  That
inflates the finding count AND overstates coverage at the same time: the
run claims to have checked cases it never reached.  Resuming after the
first unreported case keeps both numbers honest -- the aborting call stays
in the results as `:missing\=', which is what the abort report keys on."
  (let ((out nil) (todo cases) (resumes 0))
    (while todo
      (let* ((rows (nelisp-parity-fuzz--run todo))
             (idx (cl-position-if (lambda (r) (eq (nth 2 r) :missing)) rows)))
        (cond
         ((null idx) (setq out (append out rows)) (setq todo nil))
         ;; Each resume re-runs the whole remaining tail, so a chunk with many
         ;; aborting calls costs aborts x tail evaluations.  Capped -- and
         ;; what the cap dropped is COUNTED, because a silent truncation
         ;; would make the run look like it covered cases it never reached,
         ;; which is the same dishonesty the resume exists to remove.
         ((>= resumes nelisp-parity-fuzz--max-resumes)
          (setq out (append out (cl-subseq rows 0 (1+ idx))))
          (setq nelisp-parity-fuzz--dropped
                (+ nelisp-parity-fuzz--dropped (- (length todo) (1+ idx))))
          (setq todo nil))
         (t
          ;; Keep everything up to and including the aborting case, then
          ;; resume after it.  `todo' always shrinks by at least one.
          (setq resumes (1+ resumes))
          (setq out (append out (cl-subseq rows 0 (1+ idx))))
          (setq todo (nthcdr (1+ idx) todo))))))
    out))

(defun nelisp-parity-fuzz--capture (argv)
  "Run ARGV, return an alist of CASE-TEXT -> RESULT-TEXT from its ## lines."
  (with-temp-buffer
    (let ((default-directory nelisp-parity-fuzz--root))
      (apply #'call-process (car argv) nil t nil (cdr argv)))
    (goto-char (point-min))
    (let ((rows nil))
      (while (re-search-forward "^##\\(.*?\\)\t\\(.*\\)$" nil t)
        (push (cons (match-string 1) (match-string 2)) rows))
      (nreverse rows))))

(defun nelisp-parity-fuzz--aborts (cases)
  "Return the subset of CASES that KILL the standalone, one process each.

A call that ends the process cannot be caught by `condition-case', so it is
worse than a wrong answer: nothing downstream can defend against it.
(symbol-value \='unbound) was one of these until today, and the standalone\='s
`nl-jit-call-out-1\=' still is.

Candidates come from a chunked run -- a case the standalone never reported
while Emacs did means the process stopped at or before it -- and each
candidate is then re-run ALONE, because in a chunk the true culprit is the
first such case and everything after it is collateral."
  (let ((confirmed nil))
    (dolist (c cases)
      (let* ((rows (nelisp-parity-fuzz--run (list c)))
             (row (car rows)))
        (when (and row
                   (not (eq (nth 1 row) :missing))
                   (or (eq (nth 2 row) :missing)
                       (and (stringp (nth 2 row))
                            (string-match-p "aborted without signal" (nth 2 row)))))
          (push (cons c (nth 1 row)) confirmed))))
    (nreverse confirmed)))

(defun nelisp-parity-fuzz--zip (cases emacs-out nelisp-out)
  "Pair CASES with both sides' answers, keyed on the printed case text."
  (let ((out nil))
    (dolist (c cases)
      (let* ((key (nelisp-parity-fuzz--key c))
             (e (assoc key emacs-out))
             (n (assoc key nelisp-out)))
        ;; A case only one side reported is itself a finding: the standalone
        ;; stops at an uncatchable abort, and the missing tail is how that
        ;; shows.  Reported as such rather than skipped.
        (push (list c (if e (cdr e) :missing) (if n (cdr n) :missing)) out)))
    (nreverse out)))

;; ---------------------------------------------------------------------------
;; Shrinking.  A failing call is reduced by replacing each argument, one at a
;; time, with a simpler one from the pool, keeping any replacement that still
;; disagrees.  This is what turns "some call with six arguments differs" into
;; a line somebody can act on.
;; ---------------------------------------------------------------------------

(defconst nelisp-parity-fuzz--simple '(nil 0 "" '() t 1 "a")
  "Candidates tried when shrinking, simplest first.")

(defun nelisp-parity-fuzz--shrink (case)
  "Return the smallest still-failing variant of CASE.

Every candidate for one round is evaluated in a SINGLE pair of subprocesses.
Testing them one at a time costs two process spawns per candidate -- for a
four-argument call that is fifty-odd spawns per round, and the shrinker
ended up slower than the search that produced the case."
  (let ((cur case) (improved t) (rounds 0))
    (while (and improved (< rounds 4))
      (setq improved nil)
      (setq rounds (1+ rounds))
      (let ((variants nil))
        (cl-loop for i from 1 below (length cur) do
                 (cl-loop for simple in nelisp-parity-fuzz--simple do
                          (let ((try (copy-sequence cur)))
                            (setf (nth i try) simple)
                            (unless (equal try cur) (push try variants)))))
        (setq variants (nreverse (delete-dups variants)))
        (when variants
          (let* ((rows (nelisp-parity-fuzz--run variants))
                 (still (cl-find-if (lambda (r) (not (equal (nth 1 r) (nth 2 r)))) rows)))
            (when still
              (setq cur (nth 0 still))
              (setq improved t))))))
    cur))

;; ---------------------------------------------------------------------------
;; Entry point
;; ---------------------------------------------------------------------------

(defun nelisp-parity-fuzz-run ()
  (let* ((seed (string-to-number (or (getenv "NELISP_FUZZ_SEED") "1")))
         (budget (string-to-number (or (getenv "NELISP_FUZZ_CASES") "1500")))
         (shrink-cap (string-to-number (or (getenv "NELISP_FUZZ_SHRINK") "12")))
         (names (nelisp-parity-fuzz--names))
         (cases nil))
    (unless (file-executable-p nelisp-parity-fuzz--binary)
      (princ (format "parity-fuzz: FAIL (no standalone binary at %s -- run `make standalone-reader')\n"
                     nelisp-parity-fuzz--binary))
      (kill-emacs 1))
    (when (null names)
      (princ "parity-fuzz: FAIL (no shared names selected -- is docs/emacs-compat-table.txt present?)\n")
      (kill-emacs 1))
    (nelisp-parity-fuzz--seed seed)
    (princ (format "parity-fuzz: seed=%d budget=%d names=%d\n" seed budget (length names)))
    (setq nelisp-parity-fuzz--no-arity nil)
    (while (< (length cases) budget)
      (let ((c (nelisp-parity-fuzz--gen-call (nelisp-parity-fuzz--pick names))))
        (when c (push c cases))))
    (setq cases (nreverse cases))
    ;; Chunked so one uncatchable abort loses one chunk, not the whole run.
    (let ((rows nil) (chunk 100))
      (while cases
        (let ((batch (cl-subseq cases 0 (min chunk (length cases)))))
          (setq cases (nthcdr (min chunk (length cases)) cases))
          (setq rows (append rows (nelisp-parity-fuzz--run-recovering batch)))))
      ;; Uncatchable aborts are reported FIRST and separately.  Grouped in
      ;; with the wrong answers they read as one more disagreement, when in
      ;; fact they are the only class a caller cannot write around.
      ;; An abort shows two ways.  The driver's own message lands in the
      ;; RESULT field of the line whose key was already printed -- the process
      ;; died mid-form -- and every later case in the chunk goes unreported.
      ;; Keying only on the second would have missed the first entirely, and
      ;; did: the run said "0 aborts" while `(seq-filter STRING "abc")' was
      ;; killing the process in front of it.
      (let* ((suspects (mapcar (lambda (r) (nth 0 r))
                               (cl-remove-if-not
                                (lambda (r)
                                  (or (and (eq (nth 2 r) :missing)
                                           (not (eq (nth 1 r) :missing)))
                                      (and (stringp (nth 2 r))
                                           (string-match-p "aborted without signal"
                                                           (nth 2 r)))))
                                rows)))
             (aborts (and suspects (nelisp-parity-fuzz--aborts suspects))))
        (princ (format "\nparity-fuzz: %d call(s) END THE PROCESS (uncatchable -- condition-case cannot see them)\n"
                       (length aborts)))
        (dolist (a aborts)
          (princ (format "    %S\n      emacs %s\n" (car a) (cdr a)))))
      (let* ((bad (cl-remove-if (lambda (r)
                                  (or (equal (nth 1 r) (nth 2 r))
                                      (eq (nth 2 r) :missing)
                                      (and (stringp (nth 2 r))
                                           (string-match-p "aborted without signal"
                                                           (nth 2 r)))))
                                rows))
             (families (delete-dups (mapcar (lambda (r) (car (nth 0 r))) bad))))
        (princ (format "GATE-COUNT checked=%d findings=%d\n" (length rows) (length bad)))
        (let ((skipped (delete-dups (mapcar #'car nelisp-parity-fuzz--no-arity))))
          (unless (null skipped)
            (princ (format "parity-fuzz: %d name(s) generated no call (arity unreadable): %s\n"
                           (length skipped)
                           (mapconcat #'symbol-name
                                      (cl-subseq skipped 0 (min 10 (length skipped)))
                                      " ")))))
        (unless (zerop nelisp-parity-fuzz--dropped)
          (princ (format "parity-fuzz: %d case(s) NOT RUN -- a chunk hit the resume cap after repeated aborts\n"
                         nelisp-parity-fuzz--dropped)))
        (princ (format "parity-fuzz: %d/%d cases disagree, across %d name(s)\n"
                       (length bad) (length rows) (length families)))
        ;; The full list, ranked by how often the name came up.  Without it
        ;; the report shows whichever dozen the shrink cap reached, and work
        ;; gets prioritised by that accident rather than by frequency.
        (let ((counts nil))
          (dolist (r bad)
            (let* ((fam (car (nth 0 r))) (cell (assq fam counts)))
              (if cell (setcdr cell (1+ (cdr cell))) (push (cons fam 1) counts))))
          (princ "\n  divergent names, most cases first:\n")
          (let ((line "   ") (n 0))
            (dolist (c (sort counts (lambda (a b) (> (cdr a) (cdr b)))))
              (setq line (format "%s %s(%d)" line (car c) (cdr c)))
              (setq n (1+ n))
              (when (> (length line) 92) (princ (concat line "\n")) (setq line "   ")))
            (unless (string= line "   ") (princ (concat line "\n")))))
        ;; One shrunk representative per NAME: twenty reports of the same
        ;; defect read as twenty defects, and the first thing anybody does
        ;; with them is group by name anyway.
        (let ((shown 0))
          (dolist (fam families)
            (when (< shown shrink-cap)
              (setq shown (1+ shown))
              (let* ((rep (cl-find-if (lambda (r) (eq (car (nth 0 r)) fam)) bad))
                     (small (nelisp-parity-fuzz--shrink (nth 0 rep)))
                     (row (car (nelisp-parity-fuzz--run (list small)))))
                (princ (format "\n  %S\n    emacs   %s\n    nelisp  %s\n"
                               small (nth 1 row) (nth 2 row))))))
          (when (> (length families) shrink-cap)
            (princ (format "\n  ... and %d more name(s) not shrunk (NELISP_FUZZ_SHRINK to raise)\n"
                           (- (length families) shrink-cap)))))
        (if bad
            (princ "parity-fuzz: FINDINGS (each is a name whose answer differs from Emacs)\n")
          (princ "parity-fuzz: PASS (no disagreement in this budget)\n"))))))

;; Loadable as a library when NELISP_FUZZ_NORUN is set, so the generator and
;; the runner can be exercised from another batch session without kicking off
;; a whole sweep -- which is how the 13-of-60 truncation below was diagnosed.
(unless (getenv "NELISP_FUZZ_NORUN")
  (nelisp-parity-fuzz-run))

;;; nelisp-parity-fuzz.el ends here
