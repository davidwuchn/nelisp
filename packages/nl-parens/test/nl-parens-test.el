;;; nl-parens-test.el --- Tests for nl-parens -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'nl-parens)

(defun nl-parens-test--with-file (text function)
  "Call FUNCTION with a temporary file containing TEXT."
  (let ((path (make-temp-file "nl-parens-test-" nil ".el")))
    (unwind-protect
        (progn
          (with-temp-file path (insert text))
          (funcall function path))
      (delete-file path))))

(defun nl-parens-test--contents (path)
  "Return the complete contents of PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(ert-deftest nl-parens-balanced-file-is-clean ()
  (nl-parens-test--with-file "(defun nl-parens-test-ok ()\n  1)\n"
    (lambda (path) (should-not (nl-parens-check-file path)))))

(ert-deftest nl-parens-missing-defun-names-and-locates-form ()
  (nl-parens-test--with-file "(defun nl-parens-test-missing ()\n  1\n"
    (lambda (path)
      (let ((finding (car (nl-parens-check-file path))))
        (should (eq (plist-get finding :kind) 'parens-missing))
        (should (= (plist-get finding :depth) 1))
        (should (eq (plist-get finding :name) 'nl-parens-test-missing))
        (should (= (plist-get finding :line) 1))
        (should (= (plist-get finding :end-line) 2))
        (should (= (plist-get finding :insert-line) 2))
        (should-not (plist-get finding :inferred))))))

(ert-deftest nl-parens-docstring-column-zero-open-is-not-a-form ()
  (nl-parens-test--with-file
      "(defun nl-ns-scan-forms (forms)\n  \"Return a plist describing FORMS, the top-level forms of one file.\nKeys: `:defines' (list of symbols, in order), `:definition-forms'\n(symbol/form pairs), `:requires' and `:provides' ...\n...\")\n"
    (lambda (path) (should-not (nl-parens-check-file path)))))

(ert-deftest nl-parens-ignores-parens-in-string ()
  (nl-parens-test--with-file "(defun f () \"a ( b\")\n"
    (lambda (path) (should-not (nl-parens-check-file path)))))

(ert-deftest nl-parens-ignores-character-literals ()
  (nl-parens-test--with-file "(defun f () (list ?\\( ?\\)))\n"
    (lambda (path) (should-not (nl-parens-check-file path)))))

(ert-deftest nl-parens-ignores-commented-closer ()
  (nl-parens-test--with-file "(defun f ()\n  ;; )\n  1)\n"
    (lambda (path) (should-not (nl-parens-check-file path)))))

(ert-deftest nl-parens-extra-is-reported-but-not-fixed ()
  (nl-parens-test--with-file "(defun nl-parens-test-extra ()\n  1))\n"
    (lambda (path)
      (let ((before (nl-parens-test--contents path))
            (finding (car (nl-parens-check-file path))))
        (should (eq (plist-get finding :kind) 'parens-extra))
        (should (= (plist-get finding :depth) -1))
        (should (= (nl-parens-fix-file path) 0))
        (should (equal before (nl-parens-test--contents path)))))))

(ert-deftest nl-parens-two-broken-forms-are-separate ()
  (nl-parens-test--with-file
      "(defun nl-parens-test-first ()\n  1\n(defun nl-parens-test-second ()\n  2\n"
    (lambda (path)
      (let ((findings (nl-parens-check-file path)))
        (should (= (length findings) 2))
        (should (equal (mapcar (lambda (f) (plist-get f :name)) findings)
                       '(nl-parens-test-first nl-parens-test-second)))
        (should (equal (plist-get (car findings) :absorbed)
                       '(nl-parens-test-second)))))))

(ert-deftest nl-parens-fix-file-restores-exact-correct-file ()
  (let ((correct "(defun nl-parens-test-fixed ()\n  1)\n")
        (broken "(defun nl-parens-test-fixed ()\n  1\n"))
    (nl-parens-test--with-file broken
      (lambda (path)
        (should (= (nl-parens-fix-file path) 1))
        (should (equal (nl-parens-test--contents path) correct))
        (should-not (nl-parens-check-file path))
        (should (= (nl-parens-fix-file path) 0))))))

(ert-deftest nl-parens-fix-file-uses-indentation-not-form-end ()
  (let ((correct
         "(defun nl-parens-test-indented (repairs)\n  (let ((findings nil))\n    (setq findings\n          (cons (list :kind 'thing\n                      :end-line 1)\n                findings))\n    (cons (nreverse findings) repairs)))\n")
        (broken
         "(defun nl-parens-test-indented (repairs)\n  (let ((findings nil))\n    (setq findings\n          (cons (list :kind 'thing\n                      :end-line 1\n                findings))\n    (cons (nreverse findings) repairs)))\n"))
    (nl-parens-test--with-file broken
      (lambda (path)
        (let ((finding (car (nl-parens-check-file path))))
          (should (plist-get finding :inferred))
          (should (= (plist-get finding :insert-line) 5))
          (should (= (plist-get finding :end-line) 7)))
        (let ((plan (nl-parens-fix-file path t)))
          (should (= (length plan) 1))
          (should (= (plist-get (car plan) :line) 5))
          (should (equal (plist-get (car plan) :text) ")")))
        (should (equal (nl-parens-test--contents path) broken))
        (should (= (nl-parens-fix-file path) 1))
        (should (equal (nl-parens-test--contents path) correct))))))

(ert-deftest nl-parens-indentation-boundary-closes-list-before-sibling ()
  (nl-parens-test--with-file
      "(setq findings\n      (cons (list :kind kind\n                  :line line\n                  :name name\n                  :end-line end\n            findings))\n"
    (lambda (path)
      (let ((finding (car (nl-parens-check-file path))))
        (should (plist-get finding :inferred))
        (should (= (plist-get finding :insert-line) 5))
        (should (= (plist-get finding :insert-column) 31))))))

(ert-deftest nl-parens-report-supports-rich-and-sexp-styles ()
  (nl-parens-test--with-file "(defun nl-parens-test-report ()\n  1\n"
    (lambda (path)
      (let ((finding (car (nl-parens-check-file path))))
        (should (string-match "error: nl-parens-test-report is missing"
                              (nl-parens-report (list finding) 'rich)))
        (should (string-match "insert `)' here"
                              (nl-parens-report (list finding) 'rich)))
        (should (string-match ":insert-line"
                              (nl-parens-report (list finding) 'sexp)))))))

(provide 'nl-parens-test)

;;; nl-parens-test.el ends here
