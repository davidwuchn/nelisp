;;; nelisp-append-fast-path-test.el --- `append' fast-path semantics gate  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `append' in `scripts/nelisp-stdlib-prelude.el' carries a fast path for
;; its overwhelmingly common shape (every non-final argument nil or a
;; cons) that walks each argument once, inline, instead of routing
;; through `nelisp--check-seq-list' (a properness pre-scan),
;; `nelisp--append-collect' (a per-arg helper call) and
;; `nelisp--doc200-check-string-mix' (a string-mix scan that can only
;; ever fire between two strings, so it is skipped whenever every
;; non-final argument is list-shaped).  Every case below was checked
;; against GNU Emacs before being written in, and each is run against
;; the actual built `target/nelisp' binary so a regression in either
;; the fast path or its slow-path fallback shows up here rather than in
;; a consumer three layers away.

;;; Code:

(require 'ert)

(defun nelisp-append-fast-path--standalone-eval (expression)
  "Evaluate EXPRESSION on the built standalone reader and return its output."
  (let ((binary (expand-file-name "target/nelisp" default-directory)))
    (unless (file-executable-p binary)
      (ert-skip "target/nelisp is not built; standalone-reader gate owns it"))
    (with-temp-buffer
      (let ((rc (call-process binary nil t nil "--eval" expression)))
        (unless (= rc 0)
          (ert-fail (format "standalone expression failed: rc=%S output=%S"
                            rc (buffer-string))))
        (string-trim-right (buffer-string))))))

(defmacro nelisp-append-fast-path--deftest (name expr expected)
  "Define an ERT test NAME asserting EXPR prints as EXPECTED on the standalone."
  `(ert-deftest ,name ()
     (should (equal (nelisp-append-fast-path--standalone-eval ,expr) ,expected))))

;; -- zero / one argument -------------------------------------------------

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-zero-args
 "(append)"
 "nil")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-one-arg-uncopied
 "(let ((x (list 1 2 3))) (list (append x) (eq (append x) x)))"
 "((1 2 3) t)")

;; -- fast path: every non-final arg nil or cons --------------------------

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-two-lists
 "(append '(1 2) '(3))"
 "(1 2 3)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-nil-args
 "(append nil nil)"
 "nil")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-nil-non-final-preserves-tail-identity
 "(let ((x (list 5 6))) (eq (append nil x) x))"
 "t"
 )

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-final-arg-shared-not-copied
 "(let ((x (list 9))) (eq (cdr (append '(1) x)) x))"
 "t")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-final-arg-any-value
 "(append '(1 2) 3)"
 "(1 2 . 3)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-several-list-and-nil-args
 "(append '(1 2) nil '(3) nil '(4 5))"
 "(1 2 3 4 5)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-apply-over-list-of-lists
 "(apply #'append (list '(1 2) '(3 4) '(5) nil '(6)))"
 "(1 2 3 4 5 6)")

;; -- slow-path fallback: vector / string / mixed non-final args ---------

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-vector-non-final-arg
 "(append [1 2 3] nil)"
 "(1 2 3)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-string-non-final-arg-is-codepoints
 "(append \"abc\" nil)"
 "(97 98 99)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-mixed-list-vector-string-args
 "(append '(1 2) [3 4] \"56\" nil)"
 "(1 2 3 4 53 54)")

;; -- error signaling: dotted list / non-sequence -------------------------

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-dotted-non-final-arg-names-the-tail
 "(condition-case e (append '(1 2 . 3) nil) (error e))"
 "(wrong-type-argument listp 3)")

(nelisp-append-fast-path--deftest
 nelisp-append-fast-path-non-sequence-non-final-arg
 "(condition-case e (append 5 nil) (error e))"
 "(wrong-type-argument sequencep 5)")

;;; nelisp-append-fast-path-test.el ends here
