;;; nl-condition-standalone-smoke.el --- run nl-condition tests on target/nelisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone acceptance gate for Doc 169 Phase 4: run the exact ERT
;; test bodies from `nl-condition-test.el' on `target/nelisp' (no ert
;; there).  Reuses the mini ert shim from the nl-prelude smoke runner
;; by loading it first; that file also loads and runs the nl-prelude
;; suite, so this smoke gates both packages.
;;
;; Run from the repository root:
;;
;;   ./target/nelisp --load packages/nl-condition/test/nl-condition-standalone-smoke.el

;;; Code:

;; Installs the shim, loads nl-prelude + its tests, runs them (errors
;; on failure), and leaves `nl-smoke--tests' populated.
(load "packages/nl-prelude/test/nl-prelude-standalone-smoke.el")

;; Reset the registry and run only this package's tests.
(setq nl-smoke--tests nil)

(load "packages/nl-condition/src/nl-condition.el")
(load "packages/nl-condition/test/nl-condition-test.el")

(let ((tests (reverse nl-smoke--tests))
      (ran 0)
      (failures nil))
  (while tests
    (let ((test (car tests)))
      (condition-case err
          (progn
            (funcall (cdr test))
            (setq ran (1+ ran)))
        (error
         (setq failures
               (cons (format "%s: %S" (car test) err) failures)))))
    (setq tests (cdr tests)))
  (when failures
    (let ((all failures))
      (while all
        (princ (format "FAIL %s\n" (car all)))
        (setq all (cdr all))))
    (error "nl-condition-standalone-smoke: %d failure(s), %d passed"
           (length failures) ran))
  (when (< ran 25)
    (error "nl-condition-standalone-smoke: only %d tests ran (expected >= 25)"
           ran))
  (princ (format "nl-condition-standalone-smoke: PASS (%d tests)\n" ran)))

;;; nl-condition-standalone-smoke.el ends here