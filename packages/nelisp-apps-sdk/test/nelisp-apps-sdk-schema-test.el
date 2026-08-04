;;; nelisp-apps-sdk-schema-test.el --- ERT tests for apps SDK schema -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for the phase 1 apps SDK schema validator.

;;; Code:

(require 'ert)
(require 'nelisp-apps-sdk-schema)

(defun nelisp-apps-sdk-schema-test--manifest-result (json)
  "Validate manifest JSON and return the result plist."
  (nelisp-apps-sdk-validate-manifest json))

(defun nelisp-apps-sdk-schema-test--errors (result)
  "Return RESULT error list."
  (plist-get result :errors))

(ert-deftest nelisp-apps-sdk-schema-accepts-minimal-valid-manifest ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"permissions\":[\"time\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should (equal result '(:valid t)))))

(ert-deftest nelisp-apps-sdk-schema-accepts-full-valid-manifest ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"stopwatch\",\"name\":\"Stopwatch\",\"version\":\"1.2.3\",\"abi-version\":\"1\",\"description\":\"Simple timer app\",\"permissions\":[\"time\",\"storage\",\"bytes-string\",\"record\"],\"entrypoints\":{\"main\":\"stopwatch-main\",\"tick\":\"stopwatch-tick\"}}")))
    (should (equal result '(:valid t)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-app-id ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"name\":\"Words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"permissions\":[\"time\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: app-id"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-name ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"permissions\":[\"time\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: name"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-version ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"abi-version\":\"1\",\"permissions\":[\"time\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: version"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-abi-version ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"version\":\"1.0.0\",\"permissions\":[\"time\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: abi-version"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-permissions ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: permissions"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-missing-entrypoints ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"permissions\":[\"time\"]}")))
    (should-not (plist-get result :valid))
    (should (member "missing required field: entrypoints"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-unknown-manifest-permission ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\",\"name\":\"Words\",\"version\":\"1.0.0\",\"abi-version\":\"1\",\"permissions\":[\"time\",\"network\"],\"entrypoints\":{\"main\":\"words-main\"}}")))
    (should-not (plist-get result :valid))
    (should (member "unknown permission tag: network"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-abi-arg-unknown-type ()
  (let ((result
         (nelisp-apps-sdk-validate-abi-decl
          '(:name "host-now" :args (i64 bytes) :return string :permission time))))
    (should-not (plist-get result :valid))
    (should (member "unknown ABI arg type tag: bytes"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-abi-return-unknown-type ()
  (let ((result
         (nelisp-apps-sdk-validate-abi-decl
          '(:name "host-now" :args (i64) :return bytes :permission time))))
    (should-not (plist-get result :valid))
    (should (member "unknown ABI return type tag: bytes"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-rejects-abi-unknown-permission ()
  (let ((result
         (nelisp-apps-sdk-validate-abi-decl
          '(:name "host-now" :args (i64) :return string :permission network))))
    (should-not (plist-get result :valid))
    (should (member "unknown permission tag: network"
                    (nelisp-apps-sdk-schema-test--errors result)))))

(ert-deftest nelisp-apps-sdk-schema-malformed-json-returns-error-plist ()
  (let ((result
         (nelisp-apps-sdk-schema-test--manifest-result
          "{\"app-id\":\"words\"")))
    (should-not (plist-get result :valid))
    (should (= (length (nelisp-apps-sdk-schema-test--errors result)) 1))
    (should (string-prefix-p
             "malformed JSON: "
             (car (nelisp-apps-sdk-schema-test--errors result))))))

(provide 'nelisp-apps-sdk-schema-test)

;;; nelisp-apps-sdk-schema-test.el ends here
