;;; nelisp-shadow-differential-cases.el --- native vs prelude, same answers -*- lexical-binding: nil; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Expressions exercising names the standalone provides natively AND the
;; prelude redefines unconditionally, so loading the prelude replaces the
;; native implementation with an Elisp one.  `make
;; standalone-reader-shadow-smoke' evaluates this file twice -- once as-is,
;; once with the prelude loaded first -- and requires the two results to be
;; identical.
;;
;; Measured 2026-08-19: 70 of the 245 `shared-shadowing' names in
;; docs/emacs-compat-table.txt are also in the standalone's native builtin
;; list, and 10 of those are defined in the prelude, which is the set both
;; halves of a run can actually reach.  Nothing here diverged when the file
;; was written; the point is that it stays that way.
;;
;; The class is not hypothetical.  Three defects on 2026-08-19 were an
;; unconditional definition landing on a working one: `provide'/`featurep'
;; fset over the native builtins while `require' stayed native, a
;; `string-match-p' that recognised five literal regexps and answered nil to
;; everything else, and an `error-message-string' that dropped the error
;; symbol.  Each was found by hand, late, a long way from where it was
;; introduced.  A differential is how a machine finds the next one.
;;
;; Add a case when a prelude definition starts covering more ground, and
;; keep every expression answerable by BOTH implementations -- an expression
;; only the prelude can evaluate proves nothing about agreement.

;;; Code:

(list
 ;; format
 (format "%s-%d" "x" 7) (format "%S" '(1 . 2)) (format "%5.2f" 1.5)
 (format "%c%%" 65) (format "%-4s|" "ab")
 ;; substring, including the negative and empty edges
 (substring "abcdef" 1 3) (substring "abcdef" -2) (substring "abc" 0 0)
 (substring "abcdef" 2) (substring "abcdef" 0 -3)
 ;; string=
 (string= "a" "a") (string= "a" "b") (string= "" "")
 ;; the rounding family: sign matters, and each rounds a different way
 (floor 7 2) (floor -7 2) (floor 7) (ceiling 7 2) (ceiling -7 2)
 (truncate 7 2) (truncate -7 2) (truncate 7) (mod 7 2) (mod -7 2) (mod 7 -2)
 ;; equal: structure, not identity, and 1 is not 1.0
 (equal '(1 (2 3)) '(1 (2 3))) (equal "a" "a") (equal [1 2] [1 2]) (equal 1 1.0)
 (equal nil nil) (equal '(1 . 2) '(1 . 2))
 ;; natnump
 (natnump 3) (natnump 0) (natnump -1) (natnump "x")
 ;; A leading string is a docstring only when something follows it.  When it
 ;; is the whole body it IS the body -- `(defun f () "hello")' answered nil
 ;; until 2026-08-19, in both the prelude stripper and the native `defun'
 ;; the evaluator actually dispatches.  All four edges, because getting one
 ;; right by breaking another is the easy failure here.
 (progn (defun nl-diff-a () "only") (nl-diff-a))
 (progn (defun nl-diff-b () "doc" "body") (nl-diff-b))
 (progn (defun nl-diff-c (x) "doc" x) (nl-diff-c 5))
 ;; Split rather than wrapped in `progn': a call to an empty-body function
 ;; does not write its output slot, so inside a `progn' it yields whatever
 ;; the previous form left there -- `(progn (defun d () (declare ...)) (d))'
 ;; answers `d' here and nil in Emacs.  Separate list elements get separate
 ;; slots, so these two are the honest test of the declare-only body; the
 ;; slot bug is its own defect and does not belong hidden in this one.
 (defun nl-diff-d () (declare (indent 1)))
 (nl-diff-d)
 (progn (defun nl-diff-e () "doc" (declare (indent 1)) 7) (nl-diff-e))
 (progn (defmacro nl-diff-m () "mac-only") (nl-diff-m))
 ;; maphash reaches every entry
 (let ((h (make-hash-table :test 'equal)) (n 0))
   (puthash "b" 2 h) (puthash "a" 1 h) (puthash "c" 3 h)
   (maphash (lambda (_k v) (setq n (+ n v))) h)
   n))

;;; nelisp-shadow-differential-cases.el ends here
