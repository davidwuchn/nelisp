;;; nelisp-parity-coverage.el --- how much of the shared surface the corpus touches -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; I said "buffer operations, text properties, overlays and coding systems
;; are not covered" on 2026-08-19.  That was an impression.  It is a
;; computable number: docs/emacs-compat-table.txt enumerates every name both
;; runtimes define, and test/nelisp-shadow-differential-cases.el is a file
;; that either mentions a name or does not.
;;
;; This prints the number and ratchets it, so "what we have not checked"
;; stops being a feeling and starts being a figure that can only go down.
;;
;; It counts MENTIONS, not exercise: a name that appears once in a corner of
;; one case counts as covered.  That is a real weakness and is why the
;; baseline is a floor to push up rather than a score to be proud of --
;; `make parity-fuzz' is what actually searches the space.  Two numbers that
;; measure different things beat one number that pretends to measure both.
;;
;; Run: make parity-coverage

;;; Code:

(require 'cl-lib)

(defconst nelisp-parity-coverage--table "docs/emacs-compat-table.txt")
(defconst nelisp-parity-coverage--cases "test/nelisp-shadow-differential-cases.el")
(defconst nelisp-parity-coverage--baseline "tools/parity-coverage-baseline.txt")

(defun nelisp-parity-coverage--shared ()
  "Every name both runtimes define, from the compat table."
  (let ((names nil))
    (with-temp-buffer
      (insert-file-contents nelisp-parity-coverage--table)
      (goto-char (point-min))
      (while (re-search-forward "^shared-\\(?:shadowing\\|deferring\\) +\\([^ ]+\\)" nil t)
        (push (match-string 1) names)))
    (sort (delete-dups names) #'string-lessp)))

(defun nelisp-parity-coverage--mentioned (names)
  "Split NAMES into (COVERED . UNCOVERED) by whether the cases file names them."
  (let ((body (with-temp-buffer
                (insert-file-contents nelisp-parity-coverage--cases)
                (buffer-string)))
        (covered nil) (uncovered nil))
    (dolist (n names)
      ;; Anchored on non-symbol characters so `car' does not count as covered
      ;; because `caar' appears -- the whole point is to know what is missing.
      (if (string-match-p (concat "[( '`#]" (regexp-quote n) "[ )\n\t]") body)
          (push n covered)
        (push n uncovered)))
    (cons (nreverse covered) (nreverse uncovered))))

(defun nelisp-parity-coverage--baseline-value ()
  (when (file-exists-p nelisp-parity-coverage--baseline)
    (with-temp-buffer
      (insert-file-contents nelisp-parity-coverage--baseline)
      (goto-char (point-min))
      (when (re-search-forward "^covered +\\([0-9]+\\)" nil t)
        (string-to-number (match-string 1))))))

(defconst nelisp-parity-coverage--sample 24
  "How many uncovered names to name in the report.")

(defun nelisp-parity-coverage-run ()
  (let* ((names (nelisp-parity-coverage--shared))
         (split (nelisp-parity-coverage--mentioned names))
         (covered (car split))
         (uncovered (cdr split))
         (n (length covered))
         (total (length names))
         (baseline (nelisp-parity-coverage--baseline-value)))
    (princ (format "parity-coverage: %d/%d shared names appear in %s (%d%%)\n"
                   n total nelisp-parity-coverage--cases
                   (if (zerop total) 0 (/ (* 100 n) total))))
    (princ "  not covered, a sample:\n")
    (let ((line "   ") (shown 0))
      (dolist (u uncovered)
        (when (< shown nelisp-parity-coverage--sample)
          (setq shown (1+ shown))
          (setq line (concat line " " u))
          (when (> (length line) 88) (princ (concat line "\n")) (setq line "   "))))
      (unless (string= line "   ") (princ (concat line "\n"))))
    (when (> (length uncovered) nelisp-parity-coverage--sample)
      (princ (format "    ... and %d more\n"
                     (- (length uncovered) nelisp-parity-coverage--sample))))
    ;; `checked' is the SHARED-NAME count, so a table that failed to load
    ;; cannot read as full coverage of nothing.
    (princ (format "GATE-COUNT checked=%d findings=%d\n" total (length uncovered)))
    (cond
     ((zerop total)
      (princ "parity-coverage: FAIL (no shared names -- is the compat table generated?)\n")
      (kill-emacs 1))
     ((null baseline)
      (princ (format "parity-coverage: FAIL (no `covered' line in %s)\n"
                     nelisp-parity-coverage--baseline))
      (kill-emacs 1))
     ((< n baseline)
      (princ (format "parity-coverage: FAIL (%d covered, baseline %d -- a case was removed or a name was added to the shared surface without a case; add one or lower the baseline and say why)\n"
                     n baseline))
      (kill-emacs 1))
     (t
      (when (> n baseline)
        (princ (format "    ratchet available: %d above baseline\n" (- n baseline))))
      (princ "parity-coverage: PASS\n")))))

(nelisp-parity-coverage-run)

;;; nelisp-parity-coverage.el ends here
