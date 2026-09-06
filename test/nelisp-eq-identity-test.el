;;; nelisp-eq-identity-test.el --- `eq' is identity for strings (Doc 201 §6.17)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 201 §6.17 recorded that the standalone's `eq' compared strings by
;; CONTENTS: `(eq (copy-sequence "ab") (copy-sequence "ab"))' was t until one
;; of the two was mutated, and `memq', `assq', `delq', `remq', `plist-get',
;; eq- and eql-tables, `eql', `memql' and `catch' tags all inherited it.
;; Emacs's `eq' is pointer identity for every heap object.
;;
;; Every case here is a differential against the host Emacs running this
;; suite: the form is evaluated on the host with `eval' and on target/nelisp
;; with `--eval', and the two printed values must be identical.  No expected
;; value is written down by hand, so the oracle cannot drift from Emacs.
;; Forms are deterministic and print through the value printer on both
;; sides; they avoid floats-as-values and anything else the two printers are
;; known to render differently.
;;
;; Against the bug: run against the pre-fix binary (main ac7f090dd) every
;; test but `other-types-unchanged' and `eql-and-equal-controls' fails, with
;; the standalone side answering t / ("s") / ("s" . 1) / 1 where the host
;; answers nil.
;;
;; One deliberate exclusion: `(eq 1.0 1.0)' is nil in Emacs (two boxed
;; floats) and t here (Float is an inline 32-byte Sexp with no identity of
;; its own; its bits are compared).  `(let ((f 1.0)) (eq f f))' is t on both
;; and is what code can rely on; the literal-pair case is a recorded
;; divergence, not a claim.

;;; Code:

(setq load-prefer-newer t)

(require 'ert)

(defconst nelisp-eq-identity-test--repo-root
  (let* ((this (or load-file-name buffer-file-name))
         (test-dir (and this (file-name-directory this))))
    (and test-dir
         (file-name-directory (directory-file-name test-dir))))
  "Repository root used to locate the already-built standalone binary.")

(defun nelisp-eq-identity-test--binary ()
  "Return the standalone binary, or skip the test when it is not built."
  (let ((binary (expand-file-name
                 "target/nelisp" nelisp-eq-identity-test--repo-root)))
    (unless (file-executable-p binary)
      (ert-skip "target/nelisp is not built; standalone-reader-test owns it"))
    binary))

(defun nelisp-eq-identity-test--standalone (form)
  "Evaluate FORM on target/nelisp and return its printed value."
  (let ((binary (nelisp-eq-identity-test--binary)))
    (with-temp-buffer
      (let ((rc (call-process binary nil t nil
                              "--eval" (prin1-to-string form))))
        (unless (= rc 0)
          (ert-fail (format "standalone %S failed: rc=%S stdout=%S"
                            form rc (buffer-string))))
        (string-trim-right (buffer-string))))))

(defun nelisp-eq-identity-test--standalone-error (form)
  "Evaluate FORM on target/nelisp; return (EXIT-CODE STDERR) for a failing run."
  (let ((binary (nelisp-eq-identity-test--binary))
        (stderr-file (make-temp-file "nelisp-eq-identity-stderr-")))
    (unwind-protect
        (with-temp-buffer
          (let ((rc (call-process binary nil (list t stderr-file) nil
                                  "--eval" (prin1-to-string form))))
            (with-temp-buffer
              (insert-file-contents stderr-file)
              (list rc (buffer-string)))))
      (when (file-exists-p stderr-file)
        (delete-file stderr-file)))))

(defun nelisp-eq-identity-test--host (form)
  "Evaluate FORM on this Emacs and return its printed value."
  (format "%S" (eval form t)))

(defun nelisp-eq-identity-test--check (forms)
  "Assert each of FORMS prints the same value on the host and the standalone."
  (dolist (form forms)
    (should (equal (list form (nelisp-eq-identity-test--host form))
                   (list form (nelisp-eq-identity-test--standalone form))))))

(ert-deftest nelisp-eq-identity/strings-are-identity ()
  "Two string objects are never `eq'; one object always is."
  (nelisp-eq-identity-test--check
   '((eq (copy-sequence "ab") (copy-sequence "ab"))
     (eq "ab" (concat "a" "b"))
     (eq "ab" (copy-sequence "ab"))
     (eq "ab" (substring "xaby" 1 3))
     (eq "s" "s")
     (let ((s "same")) (eq s s))
     (let ((a (copy-sequence "q"))) (eq a a))
     (let ((a (copy-sequence "q"))) (eq a (car (list a))))
     (let ((a (copy-sequence "q"))) (eq a (aref (vector a) 0)))
     (funcall #'eq (copy-sequence "b") (copy-sequence "b"))
     (apply #'eq (list (copy-sequence "b") (copy-sequence "b")))
     (let ((a (copy-sequence "b"))) (funcall #'eq a a))
     ;; Mutation through one reference is visible through the other: the
     ;; two names hold ONE object, and `eq' says so before and after.
     (let* ((a (copy-sequence "ab")) (b a))
       (list (eq a b) (progn (aset a 0 ?z) (list a b (eq a b)))))
     ;; Two objects stay two objects, and `eq' says so before as well as
     ;; after one is mutated (Doc 201 §6.17's experiment answered t first).
     (let ((a (copy-sequence "ab")) (b (copy-sequence "ab")))
       (list (eq a b) (progn (aset a 0 ?z) (list a b (eq a b))))))))

(ert-deftest nelisp-eq-identity/other-types-unchanged ()
  "Symbols, fixnums, characters, nil, t, conses, vectors and bignums."
  (nelisp-eq-identity-test--check
   '((eq 'x 'x) (eq 7 7) (eq ?a ?a) (eq nil nil) (eq t t)
     (eq (list 1) (list 1)) (eq (vector 1) (vector 1))
     (let ((c (list 1))) (eq c c))
     (eq 1180591620717411303424 1180591620717411303424)
     (let ((b 1180591620717411303424)) (eq b b))
     (let ((f 1.0)) (eq f f)))))

(ert-deftest nelisp-eq-identity/list-functions ()
  "`memq'/`memql'/`assq'/`rassq'/`delq'/`remq'/`plist-*' compare with `eq'."
  (nelisp-eq-identity-test--check
   '((memq (copy-sequence "s") (list "s"))
     (let ((a (copy-sequence "s"))) (memq a (list "x" a)))
     (memql (copy-sequence "s") (list "s"))
     (member (copy-sequence "s") (list "s"))
     (assq (copy-sequence "s") (list (cons "s" 1)))
     (let ((a (copy-sequence "s"))) (assq a (list (cons a 1))))
     (assoc (copy-sequence "s") (list (cons "s" 1)))
     (rassq (copy-sequence "s") (list (cons 1 "s")))
     (delq (copy-sequence "s") (list "s" 2))
     (let ((a (copy-sequence "s"))) (delq a (list a 2)))
     (remq (copy-sequence "s") (list "s" 2))
     (delete (copy-sequence "s") (list "s" 2))
     (plist-get (list "s" 1) "s")
     (let ((k (copy-sequence "s"))) (plist-get (list k 1) k))
     (plist-get (list "s" 1) "s" #'equal)
     (plist-put (list "s" 1) (copy-sequence "s") 2)
     (plist-member (list "s" 1) (copy-sequence "s"))
     (let ((i 0) (pos nil) (needle (copy-sequence "b")))
       (dolist (x (list "a" "b"))
         (when (and (null pos) (funcall #'eq x needle)) (setq pos i))
         (setq i (1+ i)))
       pos))))

(ert-deftest nelisp-eq-identity/hash-tables-honour-test ()
  "An `eq' or `eql' table finds a key by identity, an `equal' table by value."
  (nelisp-eq-identity-test--check
   '((let ((h (make-hash-table :test 'eq)) (k (copy-sequence "k")))
       (puthash k 1 h)
       (list (gethash (copy-sequence "k") h) (gethash k h)
             (hash-table-count h)))
     (let ((h (make-hash-table :test 'eql)) (k (copy-sequence "k")))
       (puthash k 1 h)
       (list (gethash (copy-sequence "k") h) (gethash k h)))
     (let ((h (make-hash-table :test 'equal)) (k (copy-sequence "k")))
       (puthash k 1 h)
       (list (gethash (copy-sequence "k") h) (gethash k h)))
     ;; The default test is `eql'.
     (let ((h (make-hash-table)) (k (copy-sequence "k")))
       (puthash k 1 h)
       (list (gethash (copy-sequence "k") h) (gethash k h)))
     ;; Two equal-content strings are two entries in an `eq' table.
     (let ((h (make-hash-table :test 'eq)))
       (puthash (copy-sequence "k") 1 h)
       (puthash (copy-sequence "k") 2 h)
       (hash-table-count h))
     ;; `remhash' with a copy removes nothing; with the object it does.
     (let ((h (make-hash-table :test 'eq)) (k (copy-sequence "k")))
       (puthash k 1 h)
       (remhash (copy-sequence "k") h)
       (list (gethash k h) (progn (remhash k h) (gethash k h))))
     ;; Cons keys behave the same way.
     (let ((h (make-hash-table :test 'eq)) (k (list 1)))
       (puthash k 1 h)
       (list (gethash k h) (gethash (list 1) h)))
     (let ((h (make-hash-table :test 'equal)) (k (list 1)))
       (puthash k 1 h)
       (list (gethash k h) (gethash (list 1) h)))
     ;; Numbers keep value semantics under `eql' and `equal'.
     (let ((h (make-hash-table :test 'eql)))
       (puthash 1180591620717411303424 'big h)
       (puthash 7 'seven h)
       (list (gethash 1180591620717411303424 h) (gethash 7 h)))
     ;; A copy keeps the test.
     (let ((h (make-hash-table :test 'equal)))
       (puthash (copy-sequence "k") 1 h)
       (let ((c (copy-hash-table h)))
         (list (hash-table-test c) (gethash (copy-sequence "k") c)))))))

(ert-deftest nelisp-eq-identity/eql-and-equal-controls ()
  "`eql' is `eq' plus same-type numbers by value; `equal' is structural."
  (nelisp-eq-identity-test--check
   '((eql "s" (copy-sequence "s"))
     (let ((s (copy-sequence "s"))) (eql s s))
     (eql 1.0 1.0) (eql 1.0 1) (eql 7 7) (eql 0.0 -0.0)
     (eql 1180591620717411303424 1180591620717411303424)
     (eql (list 1) (list 1))
     (equal "s" (copy-sequence "s")) (equal 1.0 1.0) (equal 0.0 -0.0)
     (equal 1180591620717411303424 1180591620717411303424)
     (equal (list 1) (list 1)))))

(ert-deftest nelisp-eq-identity/catch-tags-are-identity ()
  "A `catch' tag is matched by identity; a distinct equal string is no catcher."
  (nelisp-eq-identity-test--check
   '((let ((tag (copy-sequence "x"))) (catch tag (throw tag 2)))
     (catch 'a (throw 'a 3))))
  ;; Emacs signals `no-catch' for the distinct-string throw.  The standalone
  ;; signals it too (before the fix the tag matched by contents and the form
  ;; answered 1), but its `throw' unwinds past `condition-case' handlers on
  ;; the way to the top level -- a separate, pre-existing divergence -- so
  ;; the standalone side is asserted on the process, not on a value.
  (let ((form '(catch (copy-sequence "x") (throw (copy-sequence "x") 1))))
    (should (eq 'no-catch
                (condition-case e (eval form t) (no-catch (car e)))))
    (let ((result (nelisp-eq-identity-test--standalone-error form)))
      (should (equal 1 (car result)))
      (should (string-match-p "no-catch" (cadr result))))))

(ert-deftest nelisp-eq-identity/sxhash-eq-is-identity ()
  "`sxhash-eq' hashes what `eq' compares."
  (nelisp-eq-identity-test--check
   '((/= (sxhash-eq (copy-sequence "abc")) (sxhash-eq (copy-sequence "abc")))
     (let ((s (copy-sequence "abc"))) (= (sxhash-eq s) (sxhash-eq s)))
     (let ((c (list 1 2))) (= (sxhash-eq c) (sxhash-eq c)))
     (= (sxhash-eq 'sym) (sxhash-eq 'sym))
     (= (sxhash-eq 42) (sxhash-eq 42))
     (= (sxhash-equal (copy-sequence "abc")) (sxhash-equal (copy-sequence "abc")))
     (let ((s (copy-sequence "abc"))) (= (sxhash-eql s) (sxhash-eql s)))
     (= (sxhash-eql 7) (sxhash-eql 7))
     (= (sxhash-eql 1180591620717411303424) (sxhash-eql 1180591620717411303424)))))

(provide 'nelisp-eq-identity-test)

;;; nelisp-eq-identity-test.el ends here
