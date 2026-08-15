;;; nl-safe-report-test.el --- ERT tests for nl-safe-report -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-safe-report.el' (Doc 168 Phase 6 gate data
;; collection): dump / load round-trip of the violation log, append
;; semantics, log clearing, and the summary counts (by kind, by cell,
;; static yes/no/unknown).
;;
;; Like `nl-safe-test.el', this file deliberately avoids cl-lib and
;; ert-x helpers so the same test bodies run on `target/nelisp'
;; standalone through `test/nl-safe-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-safe)
(require 'nl-safe-report)

(defun nl-safe-report-test--path ()
  "Return a scratch file path for round-trip tests, truncated empty.
On the standalone binary (detected by its `rdf' builtin) a fixed path
under target/ is used -- the smoke runs from the repo root and
target/ is gitignored; `make-temp-file' there is not trustworthy.  On
host Emacs a real temp file is made.  Either way the file starts
empty, so the fixed standalone path is safe to reuse across tests."
  (let ((path (if (fboundp 'rdf)
                  "target/nl-safe-report-test.tmp"
                (make-temp-file "nl-safe-report-test"))))
    (nl-safe-report--write-file path "")
    path))

(defun nl-safe-report-test--cleanup (path)
  "Best-effort removal of the scratch file PATH."
  (condition-case nil
      (delete-file path)
    (error nil)))

;;; Record normalization -------------------------------------------------

(ert-deftest nl-safe-report-ensure-static-defaults-unknown ()
  (let ((rec (nl-safe-report--ensure-static '(:kind borrow :cell c))))
    (should (eq (plist-get rec :static) 'unknown))
    (should (eq (plist-get rec :kind) 'borrow))))

(ert-deftest nl-safe-report-ensure-static-preserved ()
  (let ((rec (nl-safe-report--ensure-static '(:kind bounds :static yes))))
    (should (eq (plist-get rec :static) 'yes))))

;;; Clear ----------------------------------------------------------------

(ert-deftest nl-safe-report-clear-empties-log ()
  (let ((nl-safe--violation-log (list '(:kind borrow) '(:kind bounds))))
    (should (= (nl-safe-report-clear) 2))
    (should (null nl-safe--violation-log))
    (should (= (nl-safe-report-clear) 0))))

;;; Dump / load round-trip -----------------------------------------------

(ert-deftest nl-safe-report-dump-load-round-trip ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (path (nl-safe-report-test--path))
        (c (nl-cell 1))
        (p (nl-safe-mock-ptr 4)))
    ;; One borrow violation, one bounds violation, one generation
    ;; violation -- in that chronological order.
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should-error (nl-ptr-ref-u8 p 99))
    (nl-safe-mock-free p)
    (should-error (nl-ptr-ref-u8 p 0))
    (should (= (length nl-safe--violation-log) 3))
    (should (= (nl-safe-report-dump path) 3))
    ;; Dump without CLEAR leaves the in-process log alone.
    (should (= (length nl-safe--violation-log) 3))
    (let ((records (nl-safe-report-load path)))
      (should (= (length records) 3))
      ;; File order is chronological (log is newest-first).
      (should (eq (plist-get (nth 0 records) :kind) 'borrow))
      (should (eq (plist-get (nth 1 records) :kind) 'bounds))
      (should (eq (plist-get (nth 2 records) :kind) 'generation))
      ;; Kind-specific context survives the round-trip.
      (should (eq (plist-get (nth 0 records) :cell) 'c))
      (should (eq (plist-get (nth 0 records) :requested) 'exclusive))
      (should (= (plist-get (nth 1 records) :offset) 99))
      ;; Every dumped record carries the classification placeholder.
      (should (eq (plist-get (nth 0 records) :static) 'unknown))
      (should (eq (plist-get (nth 1 records) :static) 'unknown))
      (should (eq (plist-get (nth 2 records) :static) 'unknown)))
    (nl-safe-report-test--cleanup path)))

(ert-deftest nl-safe-report-dump-appends ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (path (nl-safe-report-test--path))
        (c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should (= (nl-safe-report-dump path t) 1))
    ;; CLEAR emptied the log; a second session logs one more.
    (should (null nl-safe--violation-log))
    (should-error (nl-with-borrow-mut (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should (= (nl-safe-report-dump path t) 1))
    (let ((records (nl-safe-report-load path)))
      (should (= (length records) 2))
      (should (eq (plist-get (nth 0 records) :requested) 'exclusive))
      (should (eq (plist-get (nth 0 records) :existing) 'shared))
      (should (eq (plist-get (nth 1 records) :existing) 'exclusive)))
    (nl-safe-report-test--cleanup path)))

(ert-deftest nl-safe-report-dump-empty-log ()
  (let ((nl-safe--violation-log nil)
        (path (nl-safe-report-test--path)))
    (should (= (nl-safe-report-dump path) 0))
    (should (null (nl-safe-report-load path)))
    (nl-safe-report-test--cleanup path)))

(ert-deftest nl-safe-report-load-missing-file ()
  (should (null (nl-safe-report-load
                 "target/nl-safe-report-no-such-file.tmp"))))

;;; Summary ---------------------------------------------------------------

(ert-deftest nl-safe-report-summarize-empty ()
  (let ((s (nl-safe-report-summarize nil)))
    (should (= (plist-get s :total) 0))
    (should (null (plist-get s :by-kind)))
    (should (null (plist-get s :by-cell)))
    (should (equal (plist-get s :static) '(:yes 0 :no 0 :unknown 0)))))

(ert-deftest nl-safe-report-summarize-counts ()
  (let* ((records
          (list '(:kind borrow :cell buf :static yes)
                '(:kind borrow :cell buf :static no)
                '(:kind borrow :cell reg :static unknown)
                '(:kind bounds :op nl-ptr-ref-u8 :offset 9 :static yes)
                '(:kind generation :op nl-ptr-ref-u8)))
         (s (nl-safe-report-summarize records)))
    (should (= (plist-get s :total) 5))
    (should (equal (plist-get s :by-kind)
                   '((borrow . 3) (bounds . 1) (generation . 1))))
    (should (equal (plist-get s :by-cell) '((buf . 2) (reg . 1))))
    ;; Missing `:static' counts as unknown alongside explicit unknown.
    (should (equal (plist-get s :static) '(:yes 2 :no 1 :unknown 2)))))

(ert-deftest nl-safe-report-summarize-file-round-trip ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (path (nl-safe-report-test--path))
        (c (nl-cell 1))
        (p (nl-safe-mock-ptr 4)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should-error (nl-ptr-ref-u8 p 99))
    (nl-safe-report-dump path)
    (let ((s (nl-safe-report-summarize-file path)))
      (should (= (plist-get s :total) 2))
      (should (equal (plist-get s :by-kind) '((borrow . 1) (bounds . 1))))
      (should (equal (plist-get s :by-cell) '((c . 1))))
      ;; Fresh dumps are entirely unclassified.
      (should (equal (plist-get s :static) '(:yes 0 :no 0 :unknown 2))))
    (nl-safe-report-test--cleanup path)))

;;; nl-safe-report-test.el ends here
