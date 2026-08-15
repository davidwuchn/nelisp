;;; nl-contract-test.el --- ERT tests for nl-contract -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-contract.el' (Doc 170 Stage 4): contract
;; combinators as values, flat predicate checking (symbol and function
;; value), `nl-result-of' in both directions, and above all the blame
;; semantics of `nl-provide/contract' -- caller blame on a bad
;; argument (with the right index), implementation blame on a bad
;; return -- plus idempotent re-provide, removal, the wrap-time
;; disable flag, and the shape of the violation-log record.
;;
;; This file deliberately avoids cl-lib and ert-x helpers so the same
;; test bodies can run on `target/nelisp' standalone through the mini
;; harness in `test/nl-contract-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-contract)

;;; Test subject functions ---------------------------------------------
;;
;; Each test that wraps one of these restores it with
;; `nl-contract-remove' inside `unwind-protect', so test order does
;; not matter.

(defun nl-contract-test--add (a b)
  "Return A plus B (contract test subject)."
  (+ a b))

(defun nl-contract-test--id (x)
  "Return X unchanged (contract test subject)."
  x)

(defun nl-contract-test--const ()
  "Return the symbol `k' (zero-arity contract test subject)."
  'k)

(defvar nl-contract-test--calls 0
  "Number of times `nl-contract-test--count' ran.")

(defun nl-contract-test--count (x)
  "Increment the call counter and return X."
  (setq nl-contract-test--calls (1+ nl-contract-test--calls))
  x)

;;; Flat contracts ------------------------------------------------------

(ert-deftest nl-contract-flat-symbol-pass ()
  (should (nl-contract-check 'integerp 5)))

(ert-deftest nl-contract-flat-symbol-fail ()
  (should-not (nl-contract-check 'integerp "five")))

(ert-deftest nl-contract-flat-lambda-pass ()
  (should (nl-contract-check (lambda (v) (and (integerp v) (> v 0))) 3)))

(ert-deftest nl-contract-flat-lambda-fail ()
  (should-not (nl-contract-check (lambda (v) (and (integerp v) (> v 0))) -3)))

(ert-deftest nl-contract-flat-function-value-pass ()
  (should (nl-contract-check #'stringp "s")))

(ert-deftest nl-contract-flat-check-is-boolean ()
  ;; Truthy predicate results are normalized to t.
  (should (eq (nl-contract-check #'identity 'truthy) t)))

(ert-deftest nl-contract-check-rejects-non-contract ()
  (should-error (nl-contract-check 42 1)))

(ert-deftest nl-contract-check-nil-not-a-contract ()
  (should-error (nl-contract-check nil 1)))

;;; nl-result-of --------------------------------------------------------

(ert-deftest nl-contract-result-of-ok-pass ()
  (should (nl-contract-check (nl-result-of 'stringp 'symbolp)
                             (nl-ok "payload"))))

(ert-deftest nl-contract-result-of-ok-payload-fail ()
  (should-not (nl-contract-check (nl-result-of 'stringp 'symbolp)
                                 (nl-ok 42))))

(ert-deftest nl-contract-result-of-err-pass ()
  (should (nl-contract-check (nl-result-of 'stringp 'symbolp)
                             (nl-err 'boom))))

(ert-deftest nl-contract-result-of-err-payload-fail ()
  (should-not (nl-contract-check (nl-result-of 'stringp 'symbolp)
                                 (nl-err "not a symbol"))))

(ert-deftest nl-contract-result-of-non-result-fail ()
  (should-not (nl-contract-check (nl-result-of 'stringp 'symbolp) "bare")))

(ert-deftest nl-contract-result-of-nested ()
  (let ((c (nl-result-of (nl-result-of 'integerp 'symbolp) 'stringp)))
    (should (nl-contract-check c (nl-ok (nl-ok 1))))
    (should (nl-contract-check c (nl-ok (nl-err 'e))))
    (should-not (nl-contract-check c (nl-ok (nl-ok "s"))))
    (should (nl-contract-check c (nl-err "why")))))

;;; nl-> as a value -----------------------------------------------------

(ert-deftest nl-contract-fn-contract-flat-check-functionp ()
  ;; v1: an nl-> contract in value position only checks functionp.
  (let ((c (nl-> 'integerp 'integerp)))
    (should (nl-contract-check c (lambda (x) x)))
    (should (nl-contract-check c #'car))
    (should-not (nl-contract-check c 42))))

(ert-deftest nl-contract-arrow-needs-range ()
  (should-error (nl->)))

(ert-deftest nl-contract-arrow-zero-doms ()
  (let ((c (nl-> 'symbolp)))
    (should (equal (nl-contract-describe c) '(nl-> symbolp)))))

(ert-deftest nl-contract-describe-shapes ()
  (should (eq (nl-contract-describe 'integerp) 'integerp))
  (should (eq (nl-contract-describe (lambda (v) v)) 'function))
  (should (equal (nl-contract-describe (nl-result-of 'stringp 'symbolp))
                 '(nl-result-of stringp symbolp)))
  (should (equal (nl-contract-describe
                  (nl-> 'stringp (nl-result-of 'integerp 'symbolp)))
                 '(nl-> stringp (nl-result-of integerp symbolp)))))

;;; nl-provide/contract: pass-through ------------------------------------

(ert-deftest nl-contract-provide-good-call-passes-through ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (should (= (nl-contract-test--add 2 3) 5)))
    (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-provide-returns-names ()
  (unwind-protect
      (should (equal (nl-provide/contract
                      (nl-contract-test--add (nl-> integerp integerp integerp))
                      (nl-contract-test--id (nl-> symbolp symbolp)))
                     '(nl-contract-test--add nl-contract-test--id)))
    (nl-contract-remove 'nl-contract-test--add)
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-provide-zero-arity ()
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--const (nl-> symbolp)))
        (should (eq (nl-contract-test--const) 'k)))
    (nl-contract-remove 'nl-contract-test--const)))

(ert-deftest nl-contract-provide-rejects-missing-function ()
  (should-error
   (eval '(nl-provide/contract
           (nl-contract-test--no-such-fn (nl-> integerp integerp))))))

(ert-deftest nl-contract-provide-rejects-flat-contract ()
  ;; The top-level contract must be an nl-> function contract.
  (should-error
   (eval '(nl-provide/contract (nl-contract-test--id integerp)))))

(ert-deftest nl-contract-provide-rejects-malformed-spec ()
  (should-error (macroexpand '(nl-provide/contract nl-contract-test--id)))
  (should-error (macroexpand '(nl-provide/contract (nl-contract-test--id))))
  (should-error
   (macroexpand '(nl-provide/contract (nl-contract-test--id a b)))))

;;; Blame direction: the heart ------------------------------------------

(ert-deftest nl-contract-bad-arg-blames-caller ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (let ((data (cdr (should-error (nl-contract-test--add "one" 2)
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :function) 'nl-contract-test--add))
          (should (eq (plist-get data :blame) 'caller))
          (should (= (plist-get data :position) 0))
          (should (eq (plist-get data :contract) 'integerp))
          (should (equal (plist-get data :value) "one"))))
    (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-bad-second-arg-index ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (let ((data (cdr (should-error (nl-contract-test--add 1 'two)
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'caller))
          (should (= (plist-get data :position) 1))
          (should (eq (plist-get data :value) 'two))))
    (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-bad-return-blames-implementation ()
  (unwind-protect
      (progn
        ;; The identity function cannot turn an integer into a string:
        ;; a stringp range over an integerp call blames the implementation.
        (nl-provide/contract (nl-contract-test--id (nl-> integerp stringp)))
        (let ((data (cdr (should-error (nl-contract-test--id 5)
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :function) 'nl-contract-test--id))
          (should (eq (plist-get data :blame) 'implementation))
          (should (eq (plist-get data :position) 'return))
          (should (eq (plist-get data :contract) 'stringp))
          (should (= (plist-get data :value) 5))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-arity-mismatch-blames-caller ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (let ((data (cdr (should-error (nl-contract-test--add 1)
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'caller))
          (should (eq (plist-get data :position) 'arity))
          (should (equal (plist-get data :contract) '(arity 2)))
          (should (= (plist-get data :value) 1))))
    (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-error-is-nl-error ()
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (should-error (nl-contract-test--id "x") :type 'nl-error))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-caller-blame-skips-implementation ()
  ;; A caller violation must be caught BEFORE the original runs.
  (unwind-protect
      (progn
        (setq nl-contract-test--calls 0)
        (nl-provide/contract
         (nl-contract-test--count (nl-> integerp integerp)))
        (should-error (nl-contract-test--count "no") :type 'nl-contract-error)
        (should (= nl-contract-test--calls 0))
        (should (= (nl-contract-test--count 7) 7))
        (should (= nl-contract-test--calls 1)))
    (nl-contract-remove 'nl-contract-test--count)))

(ert-deftest nl-contract-usable-after-violation ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (should-error (nl-contract-test--add "one" 2)
                      :type 'nl-contract-error)
        (should (= (nl-contract-test--add 1 2) 3)))
    (nl-contract-remove 'nl-contract-test--add)))

;;; nl-result-of at the boundary ----------------------------------------

(ert-deftest nl-contract-result-range-ok-pass ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> nl-result-p (nl-result-of stringp symbolp))))
        (should (equal (nl-contract-test--id (nl-ok "s")) (nl-ok "s"))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-result-range-err-pass ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> nl-result-p (nl-result-of stringp symbolp))))
        (should (equal (nl-contract-test--id (nl-err 'oops)) (nl-err 'oops))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-result-range-ok-payload-blames-implementation ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> nl-result-p (nl-result-of stringp symbolp))))
        (let ((data (cdr (should-error (nl-contract-test--id (nl-ok 42))
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'implementation))
          (should (eq (plist-get data :position) 'return))
          (should (equal (plist-get data :contract)
                         '(nl-result-of stringp symbolp)))
          (should (equal (plist-get data :value) (nl-ok 42)))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-result-range-err-payload-blames-implementation ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> nl-result-p (nl-result-of stringp symbolp))))
        (let ((data (cdr (should-error (nl-contract-test--id (nl-err "s"))
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'implementation))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-result-range-non-result-blames-implementation ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> integerp (nl-result-of stringp symbolp))))
        (let ((data (cdr (should-error (nl-contract-test--id 5)
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'implementation))
          (should (= (plist-get data :value) 5))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-result-dom-blames-caller ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> (nl-result-of integerp symbolp) nl-result-p)))
        (should (equal (nl-contract-test--id (nl-ok 1)) (nl-ok 1)))
        (let ((data (cdr (should-error (nl-contract-test--id (nl-ok "s"))
                                       :type 'nl-contract-error))))
          (should (eq (plist-get data :blame) 'caller))
          (should (= (plist-get data :position) 0))))
    (nl-contract-remove 'nl-contract-test--id)))

;;; DSL spelling ---------------------------------------------------------

(ert-deftest nl-contract-dsl-lambda-predicate ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id
          (nl-> (lambda (v) (and (integerp v) (> v 0))) integerp)))
        (should (= (nl-contract-test--id 3) 3))
        (should-error (nl-contract-test--id 0) :type 'nl-contract-error))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-dsl-sharp-quoted-predicate ()
  (unwind-protect
      (progn
        (nl-provide/contract
         (nl-contract-test--id (nl-> #'integerp #'integerp)))
        (should (= (nl-contract-test--id 3) 3))
        (should-error (nl-contract-test--id "s") :type 'nl-contract-error))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-programmatic-contract-values ()
  ;; Combinators are plain functions: contracts can be built as values
  ;; and installed through the function API, no DSL involved.
  (unwind-protect
      (progn
        (nl-contract--provide-1
         'nl-contract-test--id
         (nl-> #'nl-result-p (nl-result-of #'stringp #'symbolp)))
        (should (equal (nl-contract-test--id (nl-ok "s")) (nl-ok "s")))
        (should-error (nl-contract-test--id (nl-ok 1))
                      :type 'nl-contract-error))
    (nl-contract-remove 'nl-contract-test--id)))

;;; Idempotent re-provide / remove ---------------------------------------

(ert-deftest nl-contract-reprovide-does-not-stack ()
  (unwind-protect
      (progn
        (setq nl-contract-test--calls 0)
        (nl-provide/contract
         (nl-contract-test--count (nl-> integerp integerp)))
        (nl-provide/contract
         (nl-contract-test--count (nl-> integerp integerp)))
        (should (= (nl-contract-test--count 1) 1))
        ;; One wrapper layer: the original ran exactly once per call.
        (should (= nl-contract-test--calls 1))
        ;; One remove suffices to restore the raw function.
        (should (eq (nl-contract-remove 'nl-contract-test--count)
                    'nl-contract-test--count))
        (should-not (nl-contract-wrapped-p 'nl-contract-test--count))
        (should (= (nl-contract-test--count 1) 1)))
    (nl-contract-remove 'nl-contract-test--count)))

(ert-deftest nl-contract-reprovide-replaces-contract ()
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (nl-provide/contract (nl-contract-test--id (nl-> stringp stringp)))
        ;; Only the new contract is enforced.
        (should (equal (nl-contract-test--id "s") "s"))
        (should-error (nl-contract-test--id 5) :type 'nl-contract-error))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-remove-restores-original ()
  (let ((raw (symbol-function 'nl-contract-test--id)))
    (unwind-protect
        (progn
          (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
          (should-not (eq (symbol-function 'nl-contract-test--id) raw))
          (should (eq (nl-contract-remove 'nl-contract-test--id)
                      'nl-contract-test--id))
          (should (eq (symbol-function 'nl-contract-test--id) raw))
          ;; No contract left: the "violating" call now just works.
          (should (equal (nl-contract-test--id "anything") "anything")))
      (nl-contract-remove 'nl-contract-test--id))))

(ert-deftest nl-contract-remove-unwrapped-returns-nil ()
  (should-not (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-wrapped-p-tracks-state ()
  (unwind-protect
      (progn
        (should-not (nl-contract-wrapped-p 'nl-contract-test--id))
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (should (nl-contract-wrapped-p 'nl-contract-test--id))
        (nl-contract-remove 'nl-contract-test--id)
        (should-not (nl-contract-wrapped-p 'nl-contract-test--id)))
    (nl-contract-remove 'nl-contract-test--id)))

;;; Disable flag ---------------------------------------------------------

(ert-deftest nl-contract-disabled-provide-is-no-op ()
  (let ((raw (symbol-function 'nl-contract-test--id)))
    (unwind-protect
        (let ((nl-contract--enabled nil))
          (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
          (should (eq (symbol-function 'nl-contract-test--id) raw))
          (should-not (nl-contract-wrapped-p 'nl-contract-test--id))
          ;; No checking happens at all.
          (should (equal (nl-contract-test--id "s") "s")))
      (nl-contract-remove 'nl-contract-test--id))))

(ert-deftest nl-contract-disabled-provide-returns-names ()
  (let ((nl-contract--enabled nil))
    (should (equal (nl-provide/contract
                    (nl-contract-test--id (nl-> integerp integerp)))
                   '(nl-contract-test--id)))))

(ert-deftest nl-contract-flag-gates-wrap-time-not-call-time ()
  ;; An installed wrapper keeps checking even when the flag is nil at
  ;; call time; the flag gates the wrapping act only (see README).
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (let ((nl-contract--enabled nil))
          (should-error (nl-contract-test--id "s")
                        :type 'nl-contract-error)))
    (nl-contract-remove 'nl-contract-test--id)))

;;; Violation log --------------------------------------------------------

(ert-deftest nl-contract-violation-log-record-shape ()
  (unwind-protect
      (let ((nl-safe-log-violations t)
            (nl-safe--violation-log nil))
        (nl-provide/contract
         (nl-contract-test--add (nl-> integerp integerp integerp)))
        (should-error (nl-contract-test--add 1 "two")
                      :type 'nl-contract-error)
        (should (= (length nl-safe--violation-log) 1))
        (let ((rec (car nl-safe--violation-log)))
          (should (eq (plist-get rec :kind) 'contract))
          (should (eq (plist-get rec :function) 'nl-contract-test--add))
          (should (eq (plist-get rec :blame) 'caller))
          (should (= (plist-get rec :position) 1))
          (should (eq (plist-get rec :contract) 'integerp))
          (should (equal (plist-get rec :value) "two"))))
    (nl-contract-remove 'nl-contract-test--add)))

(ert-deftest nl-contract-violation-log-return-record ()
  (unwind-protect
      (let ((nl-safe-log-violations t)
            (nl-safe--violation-log nil))
        (nl-provide/contract (nl-contract-test--id (nl-> integerp stringp)))
        (should-error (nl-contract-test--id 5) :type 'nl-contract-error)
        (let ((rec (car nl-safe--violation-log)))
          (should (eq (plist-get rec :kind) 'contract))
          (should (eq (plist-get rec :blame) 'implementation))
          (should (eq (plist-get rec :position) 'return))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-violation-log-off-by-default-switch ()
  (unwind-protect
      (let ((nl-safe-log-violations nil)
            (nl-safe--violation-log nil))
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (should-error (nl-contract-test--id "s") :type 'nl-contract-error)
        (should (null nl-safe--violation-log)))
    (nl-contract-remove 'nl-contract-test--id)))

;;; Return value fidelity ------------------------------------------------

(ert-deftest nl-contract-wrapper-preserves-return-value ()
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--id (nl-> listp listp)))
        (let ((v (list 1 2 3)))
          (should (eq (nl-contract-test--id v) v))))
    (nl-contract-remove 'nl-contract-test--id)))

(ert-deftest nl-contract-wrapper-is-a-function ()
  (unwind-protect
      (progn
        (nl-provide/contract (nl-contract-test--id (nl-> integerp integerp)))
        (should (functionp (symbol-function 'nl-contract-test--id)))
        (should (= (funcall #'nl-contract-test--id 9) 9))
        (should (= (apply #'nl-contract-test--id (list 9)) 9)))
    (nl-contract-remove 'nl-contract-test--id)))

;;; nl-contract-test.el ends here
