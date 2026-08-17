;;; nelisp-ai-gate-test.el --- tests for the gate contract -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The harness in tools/ai/ decides whether every other gate in this
;; repository is believed, and until now nothing decided whether the
;; harness was right.  `nelisp-gate-derive-status' is the rule the whole
;; contract rests on -- ran = 0 is a failure, a reasoned skip is neither
;; pass nor fail -- and a rule with no test is a rule one refactor away
;; from quietly inverting.
;;
;; The files live in tools/ai/ rather than in a package, so they are
;; loaded by path from the repository root (which is where `make test'
;; runs).  When that path is wrong these tests fail loudly rather than
;; skipping, because a harness test that skips is the exact shape of
;; problem the harness exists to prevent.

;;; Code:

(require 'ert)

(load (expand-file-name "tools/ai/nelisp-gate-lib.el") nil t)
(load (expand-file-name "tools/ai/nelisp-verify.el") nil t)

(ert-deftest nelisp-ai-gate-library-is-loaded ()
  "Fail, rather than skip, when the harness cannot be found."
  (should (fboundp 'nelisp-gate-derive-status))
  (should (fboundp 'nelisp-verify--expected)))

;;;; The rule ------------------------------------------------------------

(ert-deftest nelisp-ai-gate-zero-cases-is-a-failure ()
  "The whole contract: a gate that executed nothing is not green."
  (should (equal "fail" (nelisp-gate-derive-status 0 0 nil)))
  (should (equal "fail" (nelisp-gate-derive-status 0 0 ""))))

(ert-deftest nelisp-ai-gate-failures-fail ()
  (should (equal "fail" (nelisp-gate-derive-status 10 1 nil)))
  (should (equal "fail" (nelisp-gate-derive-status 10 10 ""))))

(ert-deftest nelisp-ai-gate-work-with-no-failures-passes ()
  (should (equal "pass" (nelisp-gate-derive-status 1 0 nil)))
  (should (equal "pass" (nelisp-gate-derive-status 4873 0 ""))))

(ert-deftest nelisp-ai-gate-a-reasoned-skip-is-its-own-outcome ()
  "A skip needs a reason; without one it is indistinguishable from a
gate that quietly stopped working."
  (should (equal "skip" (nelisp-gate-derive-status 0 0 "linux-only")))
  (should (equal "fail" (nelisp-gate-derive-status 0 0 ""))))

(ert-deftest nelisp-ai-gate-a-reason-does-not-mask-a-failure ()
  "Findings beat prose: a gate with failures is red however it explains
itself."
  (should (equal "fail" (nelisp-gate-derive-status 10 2 "some excuse"))))

(ert-deftest nelisp-ai-gate-exit-codes-follow-the-status ()
  (should (= 0 (nelisp-gate-exit-code "pass")))
  (should (= 0 (nelisp-gate-exit-code "skip")))
  (should (= 1 (nelisp-gate-exit-code "fail")))
  (should (= 1 (nelisp-gate-exit-code "unreadable"))))

;;;; The report ----------------------------------------------------------

(defmacro nelisp-ai-gate-test--in-temp-dir (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "nelisp-gate-test" t))
          (process-environment (cons (format "NELISP_GATE_DIR=%s" dir)
                                     process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun nelisp-ai-gate-test--read (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (goto-char (point-min))
    (json-parse-buffer :object-type 'alist :array-type 'list)))

(ert-deftest nelisp-ai-gate-report-round-trips ()
  (nelisp-ai-gate-test--in-temp-dir
    (let* ((file (nelisp-gate-emit :name "demo" :kind "ert"
                                   :ran 12 :passed 12 :failed 0))
           (report (nelisp-ai-gate-test--read file)))
      (should (equal (alist-get 'name report) "demo"))
      (should (equal (alist-get 'status report) "pass"))
      (should (= 12 (alist-get 'ran report))))))

(ert-deftest nelisp-ai-gate-report-escapes-hostile-text ()
  "The reason field carries error text, which contains quotes and
newlines; a report that cannot be parsed is a gate that cannot be read."
  (nelisp-ai-gate-test--in-temp-dir
    (let* ((file (nelisp-gate-emit
                  :name "demo" :ran 0 :failed 1
                  :reason "he said \"no\"\nand a backslash \\ and a tab\there"))
           (report (nelisp-ai-gate-test--read file)))
      (should (string-match-p "he said \"no\"" (alist-get 'reason report)))
      (should (string-match-p "backslash \\\\" (alist-get 'reason report))))))

(ert-deftest nelisp-ai-gate-report-requires-a-name ()
  (nelisp-ai-gate-test--in-temp-dir
    (should-error (nelisp-gate-emit :ran 1))))

;;;; The manifest --------------------------------------------------------

(ert-deftest nelisp-ai-gate-manifest-parses-comments-and-optionals ()
  (let ((file (make-temp-file "gates" nil ".expected"
                              "# a comment\n\nrequired-one\noptional-one?\n")))
    (unwind-protect
        (let* ((process-environment
                (cons (format "NELISP_GATE_MANIFEST=%s" file)
                      process-environment))
               (expected (nelisp-verify--expected)))
          (should (equal expected
                         '(("required-one" . required)
                           ("optional-one" . optional)))))
      (delete-file file))))

(ert-deftest nelisp-ai-gate-unreadable-report-is-a-finding-not-a-crash ()
  "A truncated or hand-edited report must be reported, not skipped over."
  (let ((file (make-temp-file "broken" nil ".json" "{not json")))
    (unwind-protect
        (let ((report (nelisp-verify--read-report file)))
          (should (equal "unreadable" (alist-get 'status report)))
          (should (= 0 (alist-get 'ran report))))
      (delete-file file))))

;;; nelisp-ai-gate-test.el ends here
