;;; nelisp-jit-unverified.el --- measure how much code the JIT sees unchecked  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every artifact passes `nelisp-artifact-compile-file' and every source
;; passes `make compile', so both are checked.  A body arriving at the
;; JIT may have come from `eval' or been assembled at runtime, and
;; neither ran on it -- that is the one gap building earlier cannot
;; close.
;;
;; This preload turns on `count' for a whole run and prints the tally at
;; exit.  The number is the point.  The argument for skipping Doc 170
;; Stage 5 is that real code produces no violations; a claim like that
;; should keep being checked rather than being made once, and this is
;; what keeps checking it.
;;
;; `count' is not the default policy and this does not make it one: the
;; JIT is a hot path and the check costs a walk of every body it sees.
;;
;; Usage:
;;   make test-fast EMACS="emacs -Q --batch -l scripts/nelisp-jit-unverified.el"
;; or the wrapper target:
;;   make jit-unverified

;;; Code:

;; This preload runs before the Makefile's own
;; `(setq load-prefer-newer t)', so without setting it here the require
;; below picks up a stale .elc and every function added since it was
;; compiled reads as void.
(setq load-prefer-newer t)

(dolist (dir '("lisp" "src" "packages/nelisp-jit/src"
               "packages/nl-prelude/src" "packages/nl-safe/src"
               "packages/nl-check/src"))
  (add-to-list 'load-path (expand-file-name dir)))

(require 'nelisp-jit nil t)

(when (boundp 'nelisp-jit-check-policy)
  (setq nelisp-jit-check-policy 'count)
  (when (fboundp 'nelisp-jit-check-reset)
    (nelisp-jit-check-reset))
  (add-hook
   'kill-emacs-hook
   (lambda ()
     (when (fboundp 'nelisp-jit-check-report)
       (let* ((report (nelisp-jit-check-report))
              (seen (plist-get report :seen))
              (flagged (plist-get report :flagged)))
         (princ (format "\n[jit-unverified] %d body(s) reached the JIT, %d carried a finding\n"
                        seen flagged))
         (when (and (integerp seen) (> seen 0))
           (princ (format "[jit-unverified] %.1f%% flagged\n"
                          (/ (* 100.0 flagged) seen)))))))))

;;; nelisp-jit-unverified.el ends here
