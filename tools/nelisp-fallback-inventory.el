;;; nelisp-fallback-inventory.el --- CI inventory of silent degradations -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Counts error handlers that degrade without leaving a trace, and fails
;; when a kind grows past its checked-in baseline.
;;
;; The defect this exists for, measured 2026-08-19: `compile-elisp-artifact'
;; produced a 1391-byte .neln with an empty native section and printed not one
;; line of error output, because the native compile is wrapped in a
;; `condition-case' that falls back to bytecode.  A green compile therefore
;; said nothing about whether anything had been compiled natively, and only
;; the manifest could tell the difference.  The underlying `write-region' bug
;; was a one-symbol fix; finding it was not, and the reason is that nothing
;; recorded the fall.
;;
;; Three kinds are tracked, separately, because they are not equally bad:
;;
;;   silent-fallback   `condition-case' whose handler neither records nor
;;                     re-raises.  This is the shape above: an error is
;;                     converted into a quieter, wrong answer.
;;   ignore-errors     `ignore-errors' / `with-demoted-errors' with no
;;                     recording in sight.  Often a deliberate probe, which is
;;                     why it is counted apart rather than mixed in.
;;   bare-handler      `condition-case' with the variable set to nil, so the
;;                     error object is discarded before anyone could record
;;                     it even if they wanted to.
;;   dbg-note          a live `nl_dbg_note' call.  The native subset has no
;;                     other way to report anything, so the primitive has no
;;                     enable flag to forget -- which is only safe while a
;;                     call left behind cannot reach a commit.  Baseline 0;
;;                     this is the half that makes "no flag" a design rather
;;                     than an oversight.
;;
;; A handler counts as recording when it mentions any name in
;; `nelisp-fallback-inventory--recording-functions', and as re-raising when it
;; mentions `signal', `error' or `throw'.  Both lists are matched by symbol
;; occurrence anywhere in the handler body: cheap, and it errs toward calling
;; a handler innocent, which keeps the number an undercount rather than a
;; scold.
;;
;; This gate deliberately does NOT try to tell a degrading handler from a
;; probing one by intent.  That judgement is not mechanical, and a gate that
;; guesses it would be argued with instead of acted on.  What it does is keep
;; the count from growing quietly.
;;
;; Run from the repo root:
;;   emacs --batch -Q -l tools/nelisp-fallback-inventory.el
;; or: make fallback-inventory

;;; Code:

(defconst nelisp-fallback-inventory--baseline-file
  "tools/fallback-inventory-baseline.txt")

(defconst nelisp-fallback-inventory--roots
  (let ((override (getenv "NELISP_FALLBACK_INVENTORY_ROOTS")))
    (if (and override (> (length override) 0))
        (split-string override ":" t)
      '("lisp" "scripts" "tools")))
  "Directories scanned, non-recursively, for `.el' files.
Overridable so the classifier can be pointed at a fixture and shown to
answer correctly, rather than only ever producing an aggregate nobody
can check.")

(defconst nelisp-fallback-inventory--recording-functions
  '(message princ warn display-warning
    nelisp-artifact--note-native-dispatch
    nelisp-artifact--profile-log
    nl-safe-report nl-safe-report-record
    nelisp--log nelisp-log nelisp--warn)
  "Names whose presence in a handler counts as leaving a trace.")

(defconst nelisp-fallback-inventory--reraising-functions
  '(signal error throw)
  "Names whose presence in a handler counts as not swallowing the error.")

(defconst nelisp-fallback-inventory--kinds
  '(silent-fallback ignore-errors bare-handler dbg-note))

(defun nelisp-fallback-inventory--baseline ()
  "Read the baseline as an alist of (KIND . COUNT), or nil when absent."
  (when (file-exists-p nelisp-fallback-inventory--baseline-file)
    (with-temp-buffer
      (insert-file-contents nelisp-fallback-inventory--baseline-file)
      (goto-char (point-min))
      (let ((acc nil))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (or (string-match-p "\\`[ \t]*#" line)
                        (string-match-p "\\`[ \t]*\\'" line))
              (when (string-match "\\`[ \t]*\\([^ \t]+\\)[ \t]+\\([0-9]+\\)" line)
                (push (cons (intern (match-string 1 line))
                            (string-to-number (match-string 2 line)))
                      acc))))
          (forward-line 1))
        (nreverse acc)))))

(defun nelisp-fallback-inventory--mentions-p (form names)
  "Return non-nil when FORM contains any symbol in NAMES."
  (cond
   ((symbolp form) (and form (memq form names) t))
   ((consp form)
    (or (nelisp-fallback-inventory--mentions-p (car form) names)
        (nelisp-fallback-inventory--mentions-p (cdr form) names)))
   (t nil)))

(defun nelisp-fallback-inventory--traced-p (body)
  "Return non-nil when BODY records or re-raises."
  (or (nelisp-fallback-inventory--mentions-p
       body nelisp-fallback-inventory--recording-functions)
      (nelisp-fallback-inventory--mentions-p
       body nelisp-fallback-inventory--reraising-functions)))

(defun nelisp-fallback-inventory--classify (form counts)
  "Add FORM's own contribution to COUNTS, a hash of KIND -> count."
  (when (consp form)
    (let ((head (car form)))
      (cond
       ((memq head '(ignore-errors with-demoted-errors))
        (unless (nelisp-fallback-inventory--traced-p form)
          (puthash 'ignore-errors (1+ (gethash 'ignore-errors counts 0)) counts)))
       ;; Only a CALL counts.  In `(defun nl_dbg_note ...)' the name is the
       ;; second element, not the head, so the definition is not its own
       ;; finding.
       ((eq head 'nl_dbg_note)
        (puthash 'dbg-note (1+ (gethash 'dbg-note counts 0)) counts))
       ((eq head 'condition-case)
        (let ((var (nth 1 form))
              (handlers (nthcdr 3 form)))
          (when (null var)
            (puthash 'bare-handler (1+ (gethash 'bare-handler counts 0)) counts))
          (dolist (h handlers)
            (when (consp h)
              (unless (nelisp-fallback-inventory--traced-p (cdr h))
                (puthash 'silent-fallback
                         (1+ (gethash 'silent-fallback counts 0))
                         counts))))))))))

(defun nelisp-fallback-inventory--walk (form counts)
  "Walk FORM, classifying every handler in it into COUNTS."
  (nelisp-fallback-inventory--classify form counts)
  (when (consp form)
    (let ((rest form))
      (while (consp rest)
        (nelisp-fallback-inventory--walk (car rest) counts)
        (setq rest (cdr rest))))))

(defun nelisp-fallback-inventory--only-blanks-p (start)
  "Return non-nil when only whitespace and comments lie between START and eob.
That is what tells a file that ended from a form that did not: `read'
signals `end-of-file' for both, and by then point has been dragged to
the end of the buffer either way -- so the question has to be asked from
where the read BEGAN, not from where it stopped."
  (save-excursion
    (goto-char start)
    (let ((clean t))
      (while (and clean (not (eobp)))
        (skip-chars-forward " \t\n\f\r")
        (cond
         ((eobp))
         ((eq (char-after) ?\;) (forward-line 1))
         (t (setq clean nil))))
      clean)))

(defun nelisp-fallback-inventory--scan-file (file counts)
  "Read FILE and classify every handler in it into COUNTS."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((done nil))
      (while (not done)
        (let* ((start (point))
               (form (condition-case nil
                        (read (current-buffer))
                      ;; `end-of-file' means two different things and they
                      ;; must not be conflated: the file ended, or a form did
                      ;; not.  Treating both as a clean finish made an
                      ;; unbalanced file contribute zero findings and the gate
                      ;; still pass -- this gate's own defect, of exactly the
                      ;; kind it exists to count.  Caught 2026-08-19 when a
                      ;; deliberately planted call went unreported because the
                      ;; edit that planted it left a paren open.
                      (end-of-file
                       (setq done (if (nelisp-fallback-inventory--only-blanks-p start)
                                      'eof
                                    'unreadable))
                       nil)
                      (error (setq done 'unreadable) nil))))
          (when form
            (nelisp-fallback-inventory--walk form counts))))
      done)))

(defun nelisp-fallback-inventory-run ()
  "Scan the tree, print the inventory, enforce the baseline."
  (let ((counts (make-hash-table :test 'eq))
        (scanned 0)
        (unreadable nil))
    (dolist (dir nelisp-fallback-inventory--roots)
      (when (file-directory-p dir)
        (dolist (f (directory-files dir t "\\.el\\'"))
          (setq scanned (1+ scanned))
          (when (eq (nelisp-fallback-inventory--scan-file f counts) 'unreadable)
            (push f unreadable)))))
    (let* ((baseline (nelisp-fallback-inventory--baseline))
           (total 0)
           (over nil))
      (dolist (kind nelisp-fallback-inventory--kinds)
        (let ((n (gethash kind counts 0))
              (limit (cdr (assq kind baseline))))
          (setq total (+ total n))
          (princ (format "%-18s %6d  baseline %s\n"
                         kind n (if limit (number-to-string limit) "ABSENT")))
          (cond
           ((null limit) (push (cons kind 'no-baseline) over))
           ((> n limit) (push (cons kind (- n limit)) over))
           ((< n limit)
            (princ (format "  ratchet available: %d below baseline\n"
                           (- limit n)))))))
      (dolist (f (nreverse unreadable))
        (princ (format "READ-FAIL %s\n" f)))
      ;; Machine-readable tail before the verdict, so it survives every exit
      ;; path.  `checked' counts files: it is the only number that can tell a
      ;; clean tree from a scan that never ran (contract: tools/ai/README.md).
      (princ (format "GATE-COUNT checked=%d findings=%d\n" scanned total))
      (cond
       (unreadable
        (princ "fallback-inventory: FAIL (unreadable file)\n")
        (kill-emacs 1))
       (over
        (dolist (o (nreverse over))
          (if (eq (cdr o) 'no-baseline)
              (princ (format "fallback-inventory: FAIL (%s has no baseline)\n"
                             (car o)))
            (princ (format "fallback-inventory: FAIL (%s +%d over baseline -- a new error handler that neither records nor re-raises; either record the fall or raise the baseline in the same commit)\n"
                           (car o) (cdr o)))))
        (kill-emacs 1))
       (t (princ "fallback-inventory: PASS\n"))))))

(nelisp-fallback-inventory-run)

;;; nelisp-fallback-inventory.el ends here
