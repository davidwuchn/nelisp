;;; nl-condition-test.el --- ERT tests for nl-condition -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-condition.el' (Doc 169 Phase 4): pre-unwind
;; handler execution, the decline/fallback protocol, restart
;; establishment/invocation, and -- per the design doc's explicit risk
;; note -- the interplay with `unwind-protect' and dynamic binding.
;;
;; Written without cl-lib/ert-x so the same bodies run on standalone
;; NeLisp through test/nl-condition-standalone-smoke.el.

;;; Code:

(require 'ert)
(require 'nl-condition)

(define-error 'nlc-test-error "nl-condition test error")
(define-error 'nlc-test-child "nl-condition child error" 'nlc-test-error)

(defvar nlc-test--log nil
  "Event log shared by the tests.")

(defvar nlc-test--dyn 'global
  "Dynamic variable observed from handlers to prove pre-unwind runs.")

;;; nl-signal fallback + condition-case interop -----------------------

(ert-deftest nl-condition-signal-without-handlers-is-plain-signal ()
  (let ((err (should-error (nl-signal 'nlc-test-error '(1 2))
                           :type 'nlc-test-error)))
    (should (equal err '(nlc-test-error 1 2)))))

(ert-deftest nl-condition-signal-falls-back-to-condition-case ()
  (should (equal (condition-case err
                     (nl-signal 'nlc-test-error '(payload))
                   (nlc-test-error (cdr err)))
                 '(payload))))

(ert-deftest nl-condition-declined-handler-falls-through ()
  "A handler that returns declines; the signal continues outward."
  (setq nlc-test--log nil)
  (should (equal (condition-case nil
                     (nl-handler-bind ((nlc-test-error
                                        (lambda (_c)
                                          (setq nlc-test--log
                                                (cons 'saw nlc-test--log))
                                          'declined)))
                       (nl-signal 'nlc-test-error nil))
                   (nlc-test-error 'fell-through))
                 'fell-through))
  (should (equal nlc-test--log '(saw))))

;;; Pre-unwind semantics ----------------------------------------------

(ert-deftest nl-condition-handler-runs-before-unwinding ()
  "The handler sees dynamic bindings of the signaling frame.
`condition-case' would have unwound them before its handler runs."
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c)
                           (setq nlc-test--log
                                 (cons nlc-test--dyn nlc-test--log)))))
        (let ((nlc-test--dyn 'inner))
          (nl-signal 'nlc-test-error nil)))
    (nlc-test-error nil))
  (should (equal nlc-test--log '(inner))))

(ert-deftest nl-condition-condition-case-contrast ()
  "Control experiment: `condition-case' handlers run post-unwind."
  (should (eq (condition-case nil
                  (let ((nlc-test--dyn 'inner))
                    (signal 'nlc-test-error nil))
                (nlc-test-error nlc-test--dyn))
              'global)))

(ert-deftest nl-condition-handler-receives-condition-object ()
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-error
                         (lambda (c) (setq nlc-test--log c))))
        (nl-signal 'nlc-test-error '(a b)))
    (nlc-test-error nil))
  (should (equal nlc-test--log '(nlc-test-error a b))))

(ert-deftest nl-condition-handler-matches-parent-condition ()
  "A handler bound on the parent symbol sees the child error."
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-error
                         (lambda (c) (setq nlc-test--log (car c)))))
        (nl-signal 'nlc-test-child nil))
    (error nil))
  (should (eq nlc-test--log 'nlc-test-child)))

(ert-deftest nl-condition-handler-ignores-unrelated-condition ()
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-child
                         (lambda (_c) (setq nlc-test--log 'wrong))))
        (nl-signal 'nlc-test-error nil))
    (error nil))
  (should-not nlc-test--log))

(ert-deftest nl-condition-inner-handlers-run-first ()
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c)
                           (setq nlc-test--log (cons 'outer nlc-test--log)))))
        (nl-handler-bind ((nlc-test-error
                           (lambda (_c)
                             (setq nlc-test--log (cons 'inner nlc-test--log)))))
          (nl-signal 'nlc-test-error nil)))
    (error nil))
  (should (equal nlc-test--log '(outer inner))))

(ert-deftest nl-condition-handler-sees-only-outer-handlers ()
  "Re-signaling from inside a handler must not re-enter that handler."
  (setq nlc-test--log nil)
  (condition-case nil
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c)
                           (setq nlc-test--log (cons 'outer nlc-test--log)))))
        (nl-handler-bind ((nlc-test-error
                           (lambda (_c)
                             (setq nlc-test--log (cons 'inner nlc-test--log))
                             (when (> (length nlc-test--log) 5)
                               (error "handler loop"))
                             ;; Re-signal: only the OUTER handler may see it.
                             (condition-case nil
                                 (nl-signal 'nlc-test-error nil)
                               (nlc-test-error nil)))))
          (nl-signal 'nlc-test-error nil)))
    (error nil))
  ;; inner ran once; the re-signal reached outer; then the original
  ;; signal continued outward to outer once more.
  (should (equal nlc-test--log '(outer outer inner))))

;;; Restarts ----------------------------------------------------------

(ert-deftest nl-condition-restart-normal-value ()
  "Without an invocation, nl-restart-case returns the form's value."
  (should (equal (nl-restart-case (+ 1 2) (unused () 'nope)) 3)))

(ert-deftest nl-condition-invoke-restart-basic ()
  (should (eq (nl-restart-case
                  (nl-handler-bind ((nlc-test-error
                                     (lambda (_c)
                                       (nl-invoke-restart 'use-default))))
                    (nl-signal 'nlc-test-error nil))
                (use-default () 'default))
              'default)))

(ert-deftest nl-condition-invoke-restart-with-args ()
  (should (equal (nl-restart-case
                     (nl-handler-bind ((nlc-test-error
                                        (lambda (_c)
                                          (nl-invoke-restart 'retry 20 22))))
                       (nl-signal 'nlc-test-error nil))
                   (retry (a b) (+ a b)))
                 42)))

(ert-deftest nl-condition-invoke-restart-directly ()
  "Restarts are invocable outside any signal handling."
  (should (eq (nl-restart-case
                  (nl-invoke-restart 'bail)
                (bail () 'bailed))
              'bailed)))

(ert-deftest nl-condition-missing-restart-is-control-error ()
  (should-error (nl-invoke-restart 'nowhere) :type 'nl-control-error)
  (should-error (nl-restart-case
                    (nl-invoke-restart 'not-this-one)
                  (other () 'other))
                :type 'nl-control-error))

(ert-deftest nl-condition-innermost-restart-wins ()
  (should (eq (nl-restart-case
                  (nl-restart-case
                      (nl-invoke-restart 'r)
                    (r () 'inner))
                (r () 'outer))
              'inner)))

(ert-deftest nl-condition-outer-restart-reachable-by-name ()
  (should (eq (nl-restart-case
                  (nl-restart-case
                      (nl-invoke-restart 'outer-only)
                    (inner-only () 'inner))
                (outer-only () 'outer))
              'outer)))

(ert-deftest nl-condition-find-and-compute-restarts ()
  (setq nlc-test--log nil)
  (nl-restart-case
      (nl-restart-case
          (setq nlc-test--log
                (list (nl-find-restart 'use-default)
                      (nl-find-restart 'nowhere)
                      (nl-compute-restarts)))
        (retry (p) p))
    (use-default () nil))
  (should (equal nlc-test--log
                 '(use-default nil (retry use-default)))))

(ert-deftest nl-condition-restart-frame-popped-after-exit ()
  (nl-restart-case (+ 1 1) (gone () nil))
  (should-not (nl-find-restart 'gone))
  (should (equal (nl-compute-restarts) nil)))

(ert-deftest nl-condition-restart-body-runs-with-frame-popped ()
  "Invoking a restart from within its own body must not loop."
  (should (eq (nl-restart-case
                  (nl-invoke-restart 'once)
                (once ()
                      (if (nl-find-restart 'once)
                          'still-established
                        'popped)))
              'popped)))

;;; unwind-protect interplay (the doc's explicit risk area) ------------

(ert-deftest nl-condition-cleanups-run-between-handler-and-restart ()
  "Order: handler (pre-unwind) -> cleanups -> restart body."
  (setq nlc-test--log nil)
  (nl-restart-case
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c)
                           (setq nlc-test--log (cons 'handler nlc-test--log))
                           (nl-invoke-restart 'recover))))
        (unwind-protect
            (nl-signal 'nlc-test-error nil)
          (setq nlc-test--log (cons 'cleanup nlc-test--log))))
    (recover () (setq nlc-test--log (cons 'restart nlc-test--log))))
  (should (equal nlc-test--log '(restart cleanup handler))))

(ert-deftest nl-condition-handler-runs-before-cleanups ()
  "At handler time the unwind-protect cleanup has NOT run yet."
  (setq nlc-test--log nil)
  (nl-restart-case
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c)
                           (setq nlc-test--log (cons (memq 'cleanup nlc-test--log)
                                                     nlc-test--log))
                           (nl-invoke-restart 'recover))))
        (unwind-protect
            (nl-signal 'nlc-test-error nil)
          (setq nlc-test--log (cons 'cleanup nlc-test--log))))
    (recover () nil))
  ;; The nil recorded first proves cleanup hadn't run at handler time.
  (should (equal nlc-test--log '(cleanup nil))))

(ert-deftest nl-condition-nested-cleanups-all-run-in-order ()
  (setq nlc-test--log nil)
  (nl-restart-case
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c) (nl-invoke-restart 'r))))
        (unwind-protect
            (unwind-protect
                (nl-signal 'nlc-test-error nil)
              (setq nlc-test--log (cons 'inner-cleanup nlc-test--log)))
          (setq nlc-test--log (cons 'outer-cleanup nlc-test--log))))
    (r () nil))
  (should (equal nlc-test--log '(outer-cleanup inner-cleanup))))

(ert-deftest nl-condition-dynamic-binding-restored-in-restart-body ()
  "By restart-body time the signaling frame's dynamic lets are gone."
  (should (eq (nl-restart-case
                  (nl-handler-bind ((nlc-test-error
                                     (lambda (_c) (nl-invoke-restart 'probe))))
                    (let ((nlc-test--dyn 'inner))
                      (nl-signal 'nlc-test-error nil)))
                (probe () nlc-test--dyn))
              'global)))

(ert-deftest nl-condition-handler-stack-restored-after-nonlocal-exit ()
  "Escaping through nl-handler-bind must not leak handler frames."
  (setq nlc-test--log nil)
  (nl-restart-case
      (nl-handler-bind ((nlc-test-error
                         (lambda (_c) (nl-invoke-restart 'out))))
        (nl-signal 'nlc-test-error nil))
    (out () nil))
  ;; A later nl-signal with no handlers must fall straight to signal.
  (should (equal (condition-case nil
                     (nl-signal 'nlc-test-error nil)
                   (nlc-test-error 'clean))
                 'clean)))

;;; Doc 169 section 6.2 example ---------------------------------------

(defvar nlc-test--config-calls nil)

(defun nlc-test--load-config (path)
  (setq nlc-test--config-calls (cons path nlc-test--config-calls))
  (if (equal path "/etc/app.conf")
      (nl-signal 'nlc-test-error (list path))
    (list 'config-from path)))

(ert-deftest nl-condition-doc-example-use-default ()
  (setq nlc-test--config-calls nil)
  (should (eq (nl-restart-case
                  (nl-handler-bind ((nlc-test-error
                                     (lambda (_c)
                                       (nl-invoke-restart 'use-default))))
                    (nlc-test--load-config "/etc/app.conf"))
                (use-default () 'default-config)
                (retry (path) (nlc-test--load-config path)))
              'default-config)))

(ert-deftest nl-condition-doc-example-retry ()
  (setq nlc-test--config-calls nil)
  (should (equal (nl-restart-case
                     (nl-handler-bind ((nlc-test-error
                                        (lambda (_c)
                                          (nl-invoke-restart
                                           'retry "/tmp/app.conf"))))
                       (nlc-test--load-config "/etc/app.conf"))
                   (use-default () 'default-config)
                   (retry (path) (nlc-test--load-config path)))
                 '(config-from "/tmp/app.conf")))
  (should (equal nlc-test--config-calls
                 '("/tmp/app.conf" "/etc/app.conf"))))

;;; Expansion-time validation -----------------------------------------

(ert-deftest nl-condition-bad-handler-binding-is-expansion-error ()
  (should-error (macroexpand '(nl-handler-bind ((err)) 1)))
  (should-error (macroexpand '(nl-handler-bind (err) 1))))

(ert-deftest nl-condition-bad-restart-clause-is-expansion-error ()
  (should-error (macroexpand '(nl-restart-case 1 (r))))
  (should-error (macroexpand '(nl-restart-case 1 ("r" () 1)))))

(provide 'nl-condition-test)

;;; nl-condition-test.el ends here