;;; nelisp-cl-loop-test.el --- cl-loop subset vs the host's cl-loop  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The standalone runtime ships its own `cl-loop' (an Elisp subset, in
;; `nelisp-cl-macros.el' and byte-identically in the prelude).  An
;; unrecognised clause shape expands to nil, so a loop that the subset
;; cannot model does not fail -- it silently does not run.  That is how
;; 48 of the tree's 62 `cl-loop' forms came to be dead on the standalone
;; while every host test stayed green: the host has the real macro.
;;
;; These tests close that gap the only way that means anything: every
;; case is evaluated twice, once through the subset's own expander and
;; once through the host's `cl-loop', and the two answers must be equal.
;; A shape the subset declines still expands to nil, and the comparison
;; holds it to that -- the host has to answer nil too.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelisp-cl-macros)

(defmacro nelisp-cl-loop-test--subset (&rest clauses)
  "Evaluate CLAUSES through the subset expander under test."
  (nelisp-cl-macros--loop-build clauses))

(defvar nelisp-cl-loop-test--a '(10 20 30))
(defvar nelisp-cl-loop-test--b '(x y z))
(defvar nelisp-cl-loop-test--v [1 2 3])

(defconst nelisp-cl-loop-test--cases
  '(;; one list iterator, every accumulator and both guards
    (for a in nelisp-cl-loop-test--a collect a)
    (for a in nelisp-cl-loop-test--a sum a)
    (for a in nelisp-cl-loop-test--a count (> a 15))
    (for a in nelisp-cl-loop-test--a append (list a a))
    (for a in nelisp-cl-loop-test--a when (> a 15) collect a)
    (for a in nelisp-cl-loop-test--a unless (> a 15) collect a)
    (for a in nelisp-cl-loop-test--a unless (> a 15) append (list a))
    ;; parallel iterators: the shape the subset used to decline outright
    (for a in nelisp-cl-loop-test--a for b in nelisp-cl-loop-test--b
         collect (list a b))
    (for a in nelisp-cl-loop-test--a for i from 0 collect (list a i))
    (for a in nelisp-cl-loop-test--a for b in nelisp-cl-loop-test--b
         when (eq b 'y) collect a)
    (for a in nelisp-cl-loop-test--a for b in nelisp-cl-loop-test--b
         unless (eq b 'y) collect a)
    (for a in nelisp-cl-loop-test--a for b in nelisp-cl-loop-test--b
         for i from 0 collect (list a b i))
    (for i from 0 below 3 for a in nelisp-cl-loop-test--a collect (cons i a))
    ;; the shorter iterator ends the loop
    (for a in nelisp-cl-loop-test--a for b in '(x) collect (list a b))
    ;; numeric, including the directions and the step
    (for i from 0 below 3 collect i)
    (for i from 0 to 3 collect i)
    (for i from 2 downto 0 collect i)
    (for i from 3 above 0 collect i)
    (for i from 0 below 6 by 2 collect i)
    ;; and with `from' left out, which CL allows and this tree writes
    (for i below 3 collect i)
    (for i to 3 collect i)
    (for i below 6 by 2 collect i)
    ;; tails and vectors
    (for tail on nelisp-cl-loop-test--a collect (car tail))
    (for e across nelisp-cl-loop-test--v collect e)
    (for e across nelisp-cl-loop-test--v for a in nelisp-cl-loop-test--a
         collect (list e a))
    ;; stepped values
    (for a in nelisp-cl-loop-test--a for prev = 0 then a collect prev)
    (for a in nelisp-cl-loop-test--a for s = (* a 2) collect s)
    ;; short-circuiting
    (for a in nelisp-cl-loop-test--a always (> a 5))
    (for a in nelisp-cl-loop-test--a always (> a 15))
    (for a in nelisp-cl-loop-test--a when (> a 25) return a)
    ;; termination clauses, bindings, repeat
    (for a in nelisp-cl-loop-test--a while (< a 30) collect a)
    (for a in nelisp-cl-loop-test--a until (> a 25) collect a)
    (with k = 5 for a in nelisp-cl-loop-test--a collect (+ a k))
    (repeat 3 collect 1))
  "Clause lists evaluated through both the subset and the host macro.")

(ert-deftest nelisp-cl-loop/subset-agrees-with-host ()
  "Every supported shape must answer exactly what the host's `cl-loop' does."
  (dolist (clauses nelisp-cl-loop-test--cases)
    (let ((subset (eval (cons 'nelisp-cl-loop-test--subset clauses) t))
          (host (eval (cons 'cl-loop clauses) t)))
      (should (equal subset host)))))

(ert-deftest nelisp-cl-loop/parallel-for-is-modelled ()
  "A second `for' used to make the whole shape unrecognised, and an
unrecognised shape expands to nil -- so this loop ran zero times and
answered nil while the host answered three pairs.  `emit-extern-call' in
the AOT compiler is written this way, which is how a native compile came
back with no functions in it."
  (should (nelisp-cl-macros--loop-build
           '(for a in '(1 2) for b in '(3 4) collect (list a b))))
  (should (equal (eval '(nelisp-cl-loop-test--subset
                         for a in '(1 2) for b in '(3 4) collect (list a b))
                       t)
                 '((1 3) (2 4)))))

(ert-deftest nelisp-cl-loop/unless-guards-the-next-clause ()
  "`unless' was not a clause keyword at all, so any loop using one was
declined and silently did nothing."
  (should (equal (eval '(nelisp-cl-loop-test--subset
                         for a in '(1 2 3) unless (= a 2) collect a)
                       t)
                 '(1 3))))

(ert-deftest nelisp-cl-loop/downto-counts-down ()
  "`downto' was not parsed, so the loop was declined and answered nil."
  (should (equal (eval '(nelisp-cl-loop-test--subset
                         for i from 2 downto 0 collect i)
                       t)
                 '(2 1 0))))

(provide 'nelisp-cl-loop-test)
;;; nelisp-cl-loop-test.el ends here
