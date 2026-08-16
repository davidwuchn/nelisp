;;; nl-contract-nelisp-json-test.el --- ERT for the nelisp-json contracts -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 section 7.2: the first adoption of nl-contract on a module
;; it did not grow up with.  These tests care about two things the
;; synthetic contract tests cannot show:
;;
;;   1. arming a real, already-shipped API does not change what correct
;;      calls return, and disarming restores it exactly;
;;   2. the blame the caller sees is useful -- the right party, the
;;      right argument position, the offending value.
;;
;; Every test disarms in an `unwind-protect' so a failure cannot leave
;; the rest of the suite running against wrapped functions.

;;; Code:

(require 'ert)
(require 'nl-contract-nelisp-json)

(defmacro nl-contract-nelisp-json-test--armed (&rest body)
  "Run BODY with the contracts armed, disarming afterwards."
  `(progn
     (nl-contract-nelisp-json-arm)
     (unwind-protect (progn ,@body)
       (nl-contract-nelisp-json-disarm))))

;;; Correct calls are untouched -----------------------------------------

(ert-deftest nl-contract-nelisp-json-correct-calls-unchanged ()
  (let ((plain-encode (nelisp-json-encode (list 1 2)))
        (plain-string (nelisp-json-encode-string "a\"b")))
    (nl-contract-nelisp-json-test--armed
     (should (equal (nelisp-json-encode (list 1 2)) plain-encode))
     (should (equal (nelisp-json-encode-string "a\"b") plain-string))
     (should (equal (nelisp-json-encode nil) "null"))
     (should (equal (nelisp-json-encode t) "true"))
     (should (equal (nelisp-json-encode :false) "false"))
     (should (equal (nelisp-json-encode 42) "42"))
     (should (equal (nelisp-json-encode (vector 1 2)) "[1,2]")))))

(ert-deftest nl-contract-nelisp-json-disarm-restores-original ()
  (let ((before (symbol-function 'nelisp-json-encode)))
    (nl-contract-nelisp-json-arm)
    (should-not (eq (symbol-function 'nelisp-json-encode) before))
    (nl-contract-nelisp-json-disarm)
    (should (eq (symbol-function 'nelisp-json-encode) before))))

(ert-deftest nl-contract-nelisp-json-arm-is-idempotent ()
  (let ((before (symbol-function 'nelisp-json-encode)))
    (nl-contract-nelisp-json-arm)
    (nl-contract-nelisp-json-arm)
    (unwind-protect
        ;; Re-arming must rewrap the ORIGINAL, not the wrapper, so one
        ;; disarm is enough to get back to where we started.
        (should (equal (nelisp-json-encode 1) "1"))
      (nl-contract-nelisp-json-disarm))
    (should (eq (symbol-function 'nelisp-json-encode) before))))

;;; Blame ---------------------------------------------------------------

(ert-deftest nl-contract-nelisp-json-non-string-blames-the-caller ()
  (nl-contract-nelisp-json-test--armed
   (let ((err (should-error (nelisp-json-encode-string 42)
                            :type 'nl-contract-error)))
     (let ((data (cdr err)))
       (should (eq (plist-get data :blame) 'caller))
       (should (equal (plist-get data :position) 0))
       (should (equal (plist-get data :value) 42))
       (should (eq (plist-get data :function) 'nelisp-json-encode-string))))))

(ert-deftest nl-contract-nelisp-json-unencodable-symbol-blames-the-caller ()
  "A bare symbol is the common mistake; the contract names the caller
instead of letting it surface as an encoder error from inside."
  (nl-contract-nelisp-json-test--armed
   (let ((err (should-error (nelisp-json-encode 'not-json)
                            :type 'nl-contract-error)))
     (should (eq (plist-get (cdr err) :blame) 'caller)))))

(ert-deftest nl-contract-nelisp-json-pretty-print-checks-its-input ()
  (nl-contract-nelisp-json-test--armed
   (let ((err (should-error (nelisp-json-pretty-print-string 7)
                            :type 'nl-contract-error)))
     (should (eq (plist-get (cdr err) :blame) 'caller)))))

;;; Domain predicate ----------------------------------------------------

(ert-deftest nl-contract-nelisp-json-value-p-matches-the-documented-set ()
  (dolist (ok (list nil t :false :json-false 0 1.5 "s" (vector 1)
                    (list 1 2) (make-hash-table :test 'equal)))
    (should (nl-contract-nelisp-json-value-p ok)))
  (dolist (bad '(not-json some-symbol))
    (should-not (nl-contract-nelisp-json-value-p bad))))

;;; Violation log -------------------------------------------------------

(ert-deftest nl-contract-nelisp-json-violation-reaches-the-log ()
  "Adoption is what makes the Doc 168 Phase 6 corpus non-synthetic, so
the record has to actually land."
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil))
    (nl-contract-nelisp-json-test--armed
     (ignore-errors (nelisp-json-encode-string 42)))
    (should (= (length nl-safe--violation-log) 1))
    (let ((record (car nl-safe--violation-log)))
      (should (eq (plist-get record :kind) 'contract))
      (should (eq (plist-get record :function) 'nelisp-json-encode-string)))))

(provide 'nl-contract-nelisp-json-test)

;;; nl-contract-nelisp-json-test.el ends here
