;;; nl-safe-collect-wide.el --- log violations across a whole test run  -*- lexical-binding: t; -*-

;;; Commentary:

;; `make nl-violation-corpus' runs the three suites that drive the
;; dynamic checks and collects what they provoke.  Those suites exist to
;; trigger the checks, so every record is a violation someone wrote on
;; purpose, in a single small function, with literal constants -- the
;; friendliest possible input for a static checker.  Classifying only
;; those would answer the Doc 170 section 8 gate by measuring the tests
;; rather than the code, which is why that corpus labels itself as
;; test-derived.
;;
;; This is the complement, and the reason it exists separately: the
;; corpus tool can only ever report test-derived violations, because
;; test files are all it runs.  The question it cannot answer is whether
;; anything OUTSIDE those suites produces a violation.
;;
;; This is the other half: preload it before a full run so logging stays
;; on for everything, and see whether real code produces violations at
;; all.  If it does not, the gate has no evidence either way, and the
;; document's default -- do not begin Stage 5 -- stands on the strongest
;; possible ground.
;;
;; Usage:
;;   make test-fast EMACS="emacs -Q --batch -l scripts/nl-safe-collect-wide.el"

;;; Code:

;; The preload runs before the Makefile's own -L flags, so add what is
;; needed here.
(dolist (dir '("packages/nl-prelude/src" "packages/nl-safe/src"))
  (add-to-list 'load-path (expand-file-name dir)))

(require 'nl-safe nil t)
(require 'nl-safe-report nil t)

(defvar nl-safe-collect-wide-output "build/nl-safe-violations-wide.el")

(when (boundp 'nl-safe-log-violations)
  (setq nl-safe-log-violations t)
  (setq nl-safe--violation-log nil)
  (add-hook
   'kill-emacs-hook
   (lambda ()
     (let ((count (length nl-safe--violation-log)))
       (princ (format "\n[nl-safe-wide] %d violation record(s) during this run\n"
                      count))
       (when (> count 0)
         (ignore-errors
           (make-directory
            (file-name-directory nl-safe-collect-wide-output) t)
           (nl-safe-report-dump nl-safe-collect-wide-output)
           (princ (format "[nl-safe-wide] dumped to %s\n"
                          nl-safe-collect-wide-output))))))))

;;; nl-safe-collect-wide.el ends here
