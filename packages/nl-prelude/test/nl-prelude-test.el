;;; nl-prelude-test.el --- ERT tests for nl-prelude -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-prelude.el' (Doc 169 Phase 1): Result / Option
;; construction, predicates, extraction, transforms, `nl-collect'
;; short-circuiting, and the `nl-?' early-return operator including its
;; expansion-time constraints (outside `nl-defun', crossing `lambda').
;;
;; This file deliberately avoids cl-lib and ert-x helpers so the same
;; test bodies can run on `target/nelisp' standalone through the mini
;; harness in `test/nl-prelude-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-prelude)

;;; Construction + predicates ----------------------------------------

(ert-deftest nl-prelude-ok-p-basics ()
  (should (nl-ok-p (nl-ok 1)))
  (should-not (nl-ok-p (nl-err 1)))
  (should-not (nl-ok-p 1))
  (should-not (nl-ok-p nil))
  (should-not (nl-ok-p "ok")))

(ert-deftest nl-prelude-err-p-basics ()
  (should (nl-err-p (nl-err 'boom)))
  (should-not (nl-err-p (nl-ok 'boom)))
  (should-not (nl-err-p 'boom))
  (should-not (nl-err-p nil)))

(ert-deftest nl-prelude-result-p ()
  (should (nl-result-p (nl-ok 1)))
  (should (nl-result-p (nl-err 1)))
  (should-not (nl-result-p (nl-some 1)))
  (should-not (nl-result-p nl-none))
  (should-not (nl-result-p '(1 . 2))))

(ert-deftest nl-prelude-result-equal ()
  (should (equal (nl-ok 1) (nl-ok 1)))
  (should (equal (nl-err "x") (nl-err "x")))
  (should-not (equal (nl-ok 1) (nl-err 1))))

(ert-deftest nl-prelude-ok-nil-value ()
  "ok wrapping nil stays distinguishable from err/none."
  (should (nl-ok-p (nl-ok nil)))
  (should (eq (nl-unwrap (nl-ok nil)) nil)))

(ert-deftest nl-prelude-some-p-basics ()
  (should (nl-some-p (nl-some 1)))
  (should-not (nl-some-p nl-none))
  (should-not (nl-some-p (nl-ok 1)))
  (should-not (nl-some-p 1)))

(ert-deftest nl-prelude-none-p-basics ()
  (should (nl-none-p nl-none))
  (should-not (nl-none-p nil))
  (should-not (nl-none-p (nl-some nil))))

(ert-deftest nl-prelude-option-p ()
  (should (nl-option-p (nl-some 1)))
  (should (nl-option-p nl-none))
  (should-not (nl-option-p (nl-ok 1)))
  (should-not (nl-option-p nil)))

(ert-deftest nl-prelude-some-nil-value ()
  (should (nl-some-p (nl-some nil)))
  (should (eq (nl-unwrap (nl-some nil)) nil)))

(ert-deftest nl-prelude-none-is-constant ()
  (should (eq nl-none 'nl--none))
  (should (nl-none-p 'nl--none)))

;;; Extraction --------------------------------------------------------

(ert-deftest nl-prelude-unwrap-ok ()
  (should (equal (nl-unwrap (nl-ok "value")) "value")))

(ert-deftest nl-prelude-unwrap-err-signals ()
  (let ((err (should-error (nl-unwrap (nl-err 'payload))
                           :type 'nl-unwrap-error)))
    (should (equal (cdr err) '(payload)))))

(ert-deftest nl-prelude-unwrap-some ()
  (should (equal (nl-unwrap (nl-some 42)) 42)))

(ert-deftest nl-prelude-unwrap-none-signals ()
  (should-error (nl-unwrap nl-none) :type 'nl-unwrap-error))

(ert-deftest nl-prelude-unwrap-type-error ()
  (should-error (nl-unwrap 5) :type 'nl-type-error)
  (should-error (nl-unwrap '(a b)) :type 'nl-type-error))

(ert-deftest nl-prelude-unwrap-or ()
  (should (equal (nl-unwrap-or (nl-ok 1) 9) 1))
  (should (equal (nl-unwrap-or (nl-err 'e) 9) 9))
  (should (equal (nl-unwrap-or (nl-some 1) 9) 1))
  (should (equal (nl-unwrap-or nl-none 9) 9)))

(ert-deftest nl-prelude-unwrap-or-else-err ()
  (should (equal (nl-unwrap-or-else (nl-err 3) (lambda (e) (* e 10)))
                 30)))

(ert-deftest nl-prelude-unwrap-or-else-ok-skips-fn ()
  (let ((calls 0))
    (should (equal (nl-unwrap-or-else (nl-ok 7)
                                      (lambda (_e) (setq calls (1+ calls)) 0))
                   7))
    (should (= calls 0))))

(ert-deftest nl-prelude-unwrap-or-else-none ()
  (should (equal (nl-unwrap-or-else nl-none (lambda () 'fallback))
                 'fallback)))

;;; Transform ---------------------------------------------------------

(ert-deftest nl-prelude-map-ok ()
  (should (equal (nl-map (nl-ok 2) #'1+) (nl-ok 3))))

(ert-deftest nl-prelude-map-err-passthrough ()
  (let ((e (nl-err 'boom)))
    (should (eq (nl-map e #'1+) e))))

(ert-deftest nl-prelude-map-option ()
  (should (equal (nl-map (nl-some 2) #'1+) (nl-some 3)))
  (should (eq (nl-map nl-none #'1+) nl-none)))

(ert-deftest nl-prelude-map-type-error ()
  (should-error (nl-map 2 #'1+) :type 'nl-type-error))

(ert-deftest nl-prelude-map-err-transforms ()
  (should (equal (nl-map-err (nl-err 3) #'1+) (nl-err 4))))

(ert-deftest nl-prelude-map-err-ok-passthrough ()
  (let ((r (nl-ok 3)))
    (should (eq (nl-map-err r #'1+) r))))

(ert-deftest nl-prelude-map-err-rejects-option ()
  (should-error (nl-map-err (nl-some 1) #'1+) :type 'nl-type-error))

(ert-deftest nl-prelude-and-then-ok-chain ()
  (should (equal (nl-and-then (nl-ok 2) (lambda (v) (nl-ok (* v v))))
                 (nl-ok 4)))
  (should (equal (nl-and-then (nl-ok 2) (lambda (_v) (nl-err 'no)))
                 (nl-err 'no))))

(ert-deftest nl-prelude-and-then-err-short-circuits ()
  (let ((calls 0)
        (e (nl-err 'stop)))
    (should (eq (nl-and-then e (lambda (_v) (setq calls (1+ calls)) (nl-ok 1)))
                e))
    (should (= calls 0))))

(ert-deftest nl-prelude-and-then-option ()
  (should (equal (nl-and-then (nl-some 2) (lambda (v) (nl-some (1+ v))))
                 (nl-some 3)))
  (should (eq (nl-and-then nl-none (lambda (v) (nl-some v))) nl-none)))

(ert-deftest nl-prelude-ok-to-option ()
  (should (equal (nl-ok->option (nl-ok 1)) (nl-some 1)))
  (should (eq (nl-ok->option (nl-err 'e)) nl-none)))

(ert-deftest nl-prelude-option-to-ok ()
  (should (equal (nl-option->ok (nl-some 1) 'missing) (nl-ok 1)))
  (should (equal (nl-option->ok nl-none 'missing) (nl-err 'missing))))

(ert-deftest nl-prelude-conversion-type-errors ()
  (should-error (nl-ok->option (nl-some 1)) :type 'nl-type-error)
  (should-error (nl-option->ok (nl-ok 1) 'e) :type 'nl-type-error))

;;; Aggregation -------------------------------------------------------

(ert-deftest nl-prelude-collect-all-ok ()
  (should (equal (nl-collect (list (nl-ok 1) (nl-ok 2) (nl-ok 3)))
                 (nl-ok '(1 2 3)))))

(ert-deftest nl-prelude-collect-empty ()
  (should (equal (nl-collect nil) (nl-ok nil))))

(ert-deftest nl-prelude-collect-first-err ()
  (let ((e1 (nl-err 'first))
        (e2 (nl-err 'second)))
    (should (eq (nl-collect (list (nl-ok 1) e1 (nl-ok 2) e2)) e1))))

(ert-deftest nl-prelude-collect-short-circuits ()
  "Elements after the first err are not inspected at all.
Junk after the err would signal `nl-type-error' if it were reached."
  (let ((e (nl-err 'stop)))
    (should (eq (nl-collect (list (nl-ok 1) e :junk-not-a-result)) e))))

(ert-deftest nl-prelude-collect-type-error ()
  (should-error (nl-collect (list (nl-ok 1) 42)) :type 'nl-type-error))

;;; nl-? early return -------------------------------------------------

(nl-defun nl-prelude-test--half (n)
  "Return (nl-ok N/2) for even N, else an err Result."
  (if (= (% n 2) 0)
      (nl-ok (/ n 2))
    (nl-err (list 'odd n))))

(nl-defun nl-prelude-test--quarter (n)
  (nl-let* ((h (nl-? (nl-prelude-test--half n)))
            (q (nl-? (nl-prelude-test--half h))))
    (nl-ok q)))

(ert-deftest nl-prelude-?-unwraps-ok-inline ()
  (should (equal (nl-prelude-test--quarter 8) (nl-ok 2))))

(ert-deftest nl-prelude-?-early-returns-err ()
  (should (equal (nl-prelude-test--quarter 6) (nl-err '(odd 3))))
  (should (equal (nl-prelude-test--quarter 5) (nl-err '(odd 5)))))

(nl-defun nl-prelude-test--identity-? (r)
  (nl-ok (nl-? r)))

(ert-deftest nl-prelude-?-propagates-same-err-object ()
  (let ((e (nl-err 'same)))
    (should (eq (nl-prelude-test--identity-? e) e))))

(ert-deftest nl-prelude-?-runtime-type-error ()
  (nl-defun nl-prelude-test--bad ()
    (nl-ok (nl-? 5)))
  (should-error (nl-prelude-test--bad) :type 'nl-type-error))

(ert-deftest nl-prelude-?-multiple-in-one-form ()
  (nl-defun nl-prelude-test--sum (a b)
    (nl-ok (+ (nl-? a) (nl-? b))))
  (should (equal (nl-prelude-test--sum (nl-ok 1) (nl-ok 2)) (nl-ok 3)))
  (should (equal (nl-prelude-test--sum (nl-err 'l) (nl-ok 2)) (nl-err 'l)))
  (should (equal (nl-prelude-test--sum (nl-ok 1) (nl-err 'r)) (nl-err 'r))))

(defvar nl-prelude-test--cleanup-log nil
  "Side-effect log observed by the `unwind-protect' cooperation test.")

(nl-defun nl-prelude-test--cleanup (r)
  (unwind-protect
      (nl-ok (nl-? r))
    (setq nl-prelude-test--cleanup-log
          (cons 'cleanup nl-prelude-test--cleanup-log))))

(ert-deftest nl-prelude-?-cooperates-with-unwind-protect ()
  "Early return through `unwind-protect' still runs cleanup forms."
  (setq nl-prelude-test--cleanup-log nil)
  (should (equal (nl-prelude-test--cleanup (nl-err 'e)) (nl-err 'e)))
  (should (equal nl-prelude-test--cleanup-log '(cleanup)))
  (should (equal (nl-prelude-test--cleanup (nl-ok 1)) (nl-ok 1)))
  (should (equal nl-prelude-test--cleanup-log '(cleanup cleanup))))

(ert-deftest nl-prelude-?-outside-nl-defun-is-expansion-error ()
  (should-error (macroexpand '(nl-? (nl-ok 1)))))

(ert-deftest nl-prelude-?-across-lambda-is-expansion-error ()
  (should-error (macroexpand '(nl-defun nl-prelude-test--x (xs)
                                (mapcar (lambda (x) (nl-? x)) xs))))
  (should-error (macroexpand '(nl-defun nl-prelude-test--y (x)
                                (funcall #'(lambda () (nl-? x)))))))

(ert-deftest nl-prelude-?-wrong-arity-is-expansion-error ()
  (should-error (macroexpand '(nl-defun nl-prelude-test--z ()
                                (nl-? (nl-ok 1) (nl-ok 2))))))

(ert-deftest nl-prelude-?-inside-nl-lambda ()
  (let ((f (nl-lambda (r) (nl-ok (1+ (nl-? r))))))
    (should (equal (funcall f (nl-ok 1)) (nl-ok 2)))
    (should (equal (funcall f (nl-err 'e)) (nl-err 'e)))))

(ert-deftest nl-prelude-?-nested-nl-lambda-has-own-block ()
  "An err inside a nested `nl-lambda' returns from the inner
function only; the outer `nl-defun' keeps running."
  (nl-defun nl-prelude-test--outer (rs)
    (nl-ok (mapcar (nl-lambda (r) (nl-unwrap-or (nl-? r) nil)) rs)))
  (let ((e (nl-err 'inner)))
    (should (equal (nl-prelude-test--outer (list (nl-ok (nl-ok 1)) e))
                   (nl-ok (list 1 e))))))

(ert-deftest nl-prelude-?-quoted-forms-untouched ()
  (nl-defun nl-prelude-test--quoted ()
    (nl-ok '(nl-? marker)))
  (should (equal (nl-prelude-test--quoted) (nl-ok '(nl-? marker)))))

(ert-deftest nl-prelude-defun-keeps-docstring ()
  "The docstring stays outside the `cl-block' wrapper."
  (should (equal (car (nl--wrap-?-body '("Probe docstring." (nl-ok 1))))
                 "Probe docstring."))
  ;; `documentation' does not exist on target/nelisp standalone.
  (when (fboundp 'documentation)
    (should (stringp (documentation 'nl-prelude-test--half)))))

(ert-deftest nl-prelude-defun-plain-body-still-works ()
  "`nl-defun' without any `nl-?' behaves like `defun'."
  (nl-defun nl-prelude-test--plain (a b) (+ a b))
  (should (= (nl-prelude-test--plain 1 2) 3)))

(ert-deftest nl-prelude-let*-is-let* ()
  (should (= (nl-let* ((a 1) (b (1+ a))) (+ a b)) 3)))

(provide 'nl-prelude-test)

;;; nl-prelude-test.el ends here