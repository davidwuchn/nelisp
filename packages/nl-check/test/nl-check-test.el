;;; nl-check-test.el --- ERT tests for nl-check -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-check.el' (Doc 170 sections 6.2, 6.3 and 10):
;; the must-use registry and discard detection, resource linearity
;; (leak / double consume / untracked / moved out), the unsafe-call
;; inventory, and reporting.
;;
;; The negative tests matter more than the positive ones here: a
;; checker that reports findings on correct code is worse than no
;; checker, so every "clean" shape gets an explicit test.
;;
;; No cl-lib or ert-x, so the bodies also run under the standalone
;; harness in `test/nl-check-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-check)

;;; Helpers ------------------------------------------------------------

(defun nl-check-test--kinds (form)
  "Return the finding kinds reported for FORM, in order."
  (let ((kinds nil))
    (dolist (finding (nl-check-form form))
      (setq kinds (cons (plist-get finding :kind) kinds)))
    (nreverse kinds)))

(defun nl-check-test--register ()
  "Register the fixtures the resource tests build on."
  (nl-resource-register 'test-fd #'ignore)
  (nl-must-use nl-check-test-open))

;;; must-use registry --------------------------------------------------

(ert-deftest nl-check-must-use-registers ()
  (nl-must-use nl-check-test-alpha nl-check-test-beta)
  (should (nl-check-must-use-p 'nl-check-test-alpha))
  (should (nl-check-must-use-p 'nl-check-test-beta))
  (should-not (nl-check-must-use-p 'nl-check-test-not-registered))
  (should-not (nl-check-must-use-p 42)))

(ert-deftest nl-check-must-use-rejects-non-symbols ()
  (should-error (macroexpand '(nl-must-use "open"))))

(ert-deftest nl-check-must-use-list-is-sorted ()
  (nl-must-use nl-check-test-zzz nl-check-test-aaa)
  (let ((names (nl-check-must-use-list)))
    (should (memq 'nl-check-test-aaa names))
    (should (memq 'nl-check-test-zzz names))
    (should (equal names (sort (copy-sequence names)
                               (lambda (a b)
                                 (string< (symbol-name a)
                                          (symbol-name b))))))))

;;; must-use discard detection -----------------------------------------

(ert-deftest nl-check-must-use-discarded-in-progn ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(progn (nl-check-test-open "a") 1))
                 '(must-use-discarded))))

(ert-deftest nl-check-must-use-value-position-is-clean ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds '(progn 1 (nl-check-test-open "a"))))
  (should-not (nl-check-test--kinds '(let ((x (nl-check-test-open "a"))) x)))
  (should-not (nl-check-test--kinds '(setq x (nl-check-test-open "a"))))
  (should-not (nl-check-test--kinds '(list (nl-check-test-open "a")))))

(ert-deftest nl-check-must-use-ignore-is-the-escape-hatch ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds
               '(progn (ignore (nl-check-test-open "a")) 1))))

(ert-deftest nl-check-must-use-in-let-body-statement ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(let ((y 1)) (nl-check-test-open "a") y))
                 '(must-use-discarded))))

(ert-deftest nl-check-must-use-in-while-body ()
  (nl-check-test--register)
  ;; Every form in a `while' body is a statement, including the last.
  (should (equal (nl-check-test--kinds
                  '(while c (nl-check-test-open "a")))
                 '(must-use-discarded))))

(ert-deftest nl-check-must-use-in-branch-tail-is-clean ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds
               '(if c (nl-check-test-open "a") (nl-check-test-open "b"))))
  (should-not (nl-check-test--kinds
               '(cond (c (nl-check-test-open "a")))))
  (should-not (nl-check-test--kinds
               '(when c (nl-check-test-open "a")))))

(ert-deftest nl-check-must-use-skips-quoted-forms ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds '(progn '(nl-check-test-open "a") 1))))

(ert-deftest nl-check-must-use-in-unwind-protect-cleanup ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(unwind-protect 1 (nl-check-test-open "a")))
                 '(must-use-discarded))))

;;; Resource linearity -------------------------------------------------

(ert-deftest nl-check-resource-leak-is-reported ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(let ((r (nl-resource 'test-fd 1)))
                     (nl-resource-handle r)))
                 '(resource-leak))))

(ert-deftest nl-check-resource-dropped-once-is-clean ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  (nl-resource-handle r)
                  (nl-drop r))))
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  (nl-forget r)))))

(ert-deftest nl-check-resource-double-consume-is-reported ()
  (nl-check-test--register)
  (let ((findings (nl-check-form
                   '(let ((r (nl-resource 'test-fd 1)))
                      (nl-drop r)
                      (nl-drop r)))))
    (should (equal (list (plist-get (car findings) :kind)
                         (plist-get (car findings) :count))
                   '(resource-double 2)))))

(ert-deftest nl-check-resource-drop-in-both-branches-is-clean ()
  (nl-check-test--register)
  ;; Only one arm runs, so `if' takes the maximum, not the sum.
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  (if c (nl-drop r) (nl-drop r)))))
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  (cond (c (nl-drop r)) (t (nl-drop r)))))))

(ert-deftest nl-check-resource-drop-in-loop-is-reported ()
  (nl-check-test--register)
  ;; A loop body can run more than once, so one syntactic drop is two.
  (should (equal (nl-check-test--kinds
                  '(let ((r (nl-resource 'test-fd 1)))
                     (while c (nl-drop r))))
                 '(resource-double))))

(ert-deftest nl-check-resource-captured-by-lambda-is-untracked ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(let ((r (nl-resource 'test-fd 1)))
                     (funcall (lambda () (nl-drop r)))))
                 '(resource-untracked))))

(ert-deftest nl-check-resource-passed-to-unknown-call-is-untracked ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(let ((r (nl-resource 'test-fd 1)))
                     (nl-check-test-store r)))
                 '(resource-untracked))))

(ert-deftest nl-check-resource-moved-out-is-clean ()
  (nl-check-test--register)
  ;; Returning the resource moves ownership to the caller.
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  r))))

(ert-deftest nl-check-resource-observers-do-not-count-as-moves ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds
               '(let ((r (nl-resource 'test-fd 1)))
                  (nl-resource-live-p r)
                  (nl-resource-type r)
                  (nl-resource-handle r)
                  (nl-drop r)))))

(ert-deftest nl-check-resource-non-resource-let-is-ignored ()
  (nl-check-test--register)
  (should-not (nl-check-test--kinds '(let ((r (open-file "x"))) r))))

(ert-deftest nl-check-resource-nested-let-is-scanned ()
  (nl-check-test--register)
  (should (equal (nl-check-test--kinds
                  '(defun f ()
                     (let ((a 1))
                       (let ((r (nl-resource 'test-fd 1)))
                         (nl-resource-handle r)))))
                 '(resource-leak))))

;;; Unsafe inventory ---------------------------------------------------

(ert-deftest nl-check-unsafe-call-outside-block-is-reported ()
  (should (equal (nl-check-test--kinds '(progn (ptr-read-u8 p 0)))
                 '(unsafe-call))))

(ert-deftest nl-check-unsafe-call-inside-block-is-clean ()
  (should-not (nl-check-test--kinds '(nl-unsafe (ptr-read-u8 p 0)))))

(ert-deftest nl-check-unsafe-nested-inside-block-is-clean ()
  (should-not (nl-check-test--kinds
               '(nl-unsafe (let ((x 1)) (ptr-write-u8 p 0 x))))))

(ert-deftest nl-check-unsafe-reports-each-call ()
  (let ((findings (nl-check-findings-of-kind
                   (nl-check-form '(progn (alloc-bytes 8 8)
                                          (syscall-direct 1 0 0 0 0 0 0)))
                   'unsafe-call)))
    (should (= (length findings) 2))))

;;; Entry points and reporting -----------------------------------------

(ert-deftest nl-check-forms-concatenates ()
  (nl-check-test--register)
  (should (= (length (nl-check-forms
                      '((progn (nl-check-test-open "a") 1)
                        (progn (nl-check-test-open "b") 1))))
             2)))

(ert-deftest nl-check-clean-form-has-no-findings ()
  (nl-check-test--register)
  (should-not (nl-check-form '(defun f (x) (+ x 1)))))

(ert-deftest nl-check-report-of-nothing ()
  (should (equal (nl-check-report nil) "nl-check: no findings\n")))

(ert-deftest nl-check-report-lists-each-finding ()
  (nl-check-test--register)
  (let ((report (nl-check-report
                 (nl-check-form
                  '(let ((r (nl-resource 'test-fd 1)))
                     (nl-resource-handle r))))))
    (should (string-match-p "1 finding" report))
    (should (string-match-p "resource-leak" report))
    (should (string-match-p "never dropped" report))))

(ert-deftest nl-check-findings-of-kind-filters ()
  (nl-check-test--register)
  (let ((findings (nl-check-form
                   '(progn
                      (nl-check-test-open "a")
                      (let ((r (nl-resource 'test-fd 1)))
                        (nl-resource-handle r))))))
    (should (= (length (nl-check-findings-of-kind
                        findings 'must-use-discarded))
               1))
    (should (= (length (nl-check-findings-of-kind
                        findings 'resource-leak))
               1))
    (should-not (nl-check-findings-of-kind findings 'unsafe-call))))

(ert-deftest nl-check-dotted-forms-do-not-crash ()
  "Real source files contain dotted forms (alist literals in macro
positions); every walker must tolerate improper lists (found via the
unsafe-inventory scan of lisp/nelisp-stdlib-os.el)."
  (dolist (form '((while c (f . 9))
                  (when c (f . 9))
                  (progn (f . 9) (g . 9))
                  (let ((x (f . 9))) (g . 9))
                  (cond ((c) (f . 9)))
                  (unwind-protect (f . 9) (g . 9))
                  (f (g . 9) . 9)))
    (should (listp (nl-check-form form)))))

(provide 'nl-check-test)

;;; nl-check-test.el ends here
