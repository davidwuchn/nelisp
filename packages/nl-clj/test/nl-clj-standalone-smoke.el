;;; nl-clj-standalone-smoke.el --- run nl-clj tests on target/nelisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone acceptance gate for this package's build-first Tier 1
;; slice: run the exact ERT test bodies from every `nl-clj-*-test.el'
;; file on `target/nelisp', which has no `ert'.  A minimal ert shim
;; (`ert-deftest'/`should'/`should-not'/`should-error') is installed
;; first, then the real test files are loaded and every registered
;; test body is executed -- same pattern as
;; `packages/nl-safe/test/nl-safe-standalone-smoke.el'.
;;
;; This is the real risk this package's own brief names: Doc 195 §2.1
;; measured that `cl-defstruct'/`record' print with real Emacs
;; `#s(...)' syntax but do not round-trip through `read-from-string'
;; on this exact substrate -- a genuine print/read asymmetry.  This
;; package represents every collection as a tagged plain vector
;; specifically to avoid that trap (nl-clj-core.el's Commentary); this
;; file is the proof that choice actually survives standalone load AND
;; standalone execution, not just standalone byte-compilation.
;;
;; Run from the repository root:
;;
;;   ./target/nelisp --load packages/nl-clj/test/nl-clj-standalone-smoke.el
;;
;; The final line is `nl-clj-standalone-smoke: PASS (N tests)'; any
;; failure raises an error so the process exits non-zero.
;;
;; Dependencies are loaded explicitly by path: on the standalone,
;; (require 'nl-prelude) would silently "succeed" even with the file
;; absent (Doc 195 §2's own measured `require' gap on this substrate,
;; matching this session's own memory of the same trap elsewhere), so
;; `load' is the only trustworthy path (same pattern as
;; nl-safe/nl-prelude's own smoke runners).
;;
;; On host Emacs this file is inert for `make test' (its name does not
;; match the `nl-*-test.el' glob) and the shim only installs when ert
;; is absent.

;;; Code:

(defvar nl-smoke--tests nil
  "Alist of (NAME . BODY-FN) registered by the `ert-deftest' shim.")

(unless (featurep 'ert)
  (defmacro ert-deftest (name _args &rest body)
    "Register BODY as test NAME in `nl-smoke--tests'."
    (when (and (stringp (car body)) (cdr body))
      (setq body (cdr body)))
    `(setq nl-smoke--tests
           (cons (cons ',name (lambda () ,@body)) nl-smoke--tests)))
  (defmacro should (form)
    `(let ((nl-smoke--v ,form))
       (unless nl-smoke--v
         (error "should failed: %S" ',form))
       nl-smoke--v))
  (defmacro should-not (form)
    `(let ((nl-smoke--v ,form))
       (when nl-smoke--v
         (error "should-not failed: %S" ',form))
       t))
  (defmacro should-error (form &rest keys)
    "Evaluate FORM, expect an error; return (SYMBOL . DATA).
KEYS supports `:type SYMBOL' for condition matching like ert."
    `(let* ((nl-smoke--expected (plist-get (list ,@keys) :type))
            (nl-smoke--r
             (condition-case nl-smoke--e
                 (progn ,form 'nl-smoke--no-error)
               (error nl-smoke--e))))
       (cond
        ((eq nl-smoke--r 'nl-smoke--no-error)
         (error "should-error: no error signaled by %S" ',form))
        ((and nl-smoke--expected
              (not (memq nl-smoke--expected
                         (get (car nl-smoke--r) 'error-conditions))))
         (error "should-error: expected %S, got %S"
                nl-smoke--expected nl-smoke--r))
        (t nl-smoke--r))))
  (provide 'ert))

(load "packages/nl-prelude/src/nl-prelude.el")
(load "packages/nl-clj/src/nl-clj-core.el")
(load "packages/nl-clj/src/nl-clj-atom.el")
(load "packages/nl-clj/src/nl-clj-vector.el")
(load "packages/nl-clj/src/nl-clj-hash.el")
(load "packages/nl-clj/src/nl-clj-seq.el")
(load "packages/nl-clj/src/nl-clj.el")

(load "packages/nl-clj/test/nl-clj-atom-test.el")
(load "packages/nl-clj/test/nl-clj-vector-test.el")
(load "packages/nl-clj/test/nl-clj-hash-test.el")
(load "packages/nl-clj/test/nl-clj-seq-test.el")

;; The exact risk this package's own brief names: prove the tagged-
;; vector representation round-trips through `prin1'/`read-from-string'
;; on THIS substrate, where Doc 195 §2.1 measured `record' does not.
(let* ((v (nl-clj-vector 1 2 3))
       (printed (prin1-to-string v))
       (reread (car (read-from-string printed))))
  (unless (equal v reread)
    (error "nl-clj-standalone-smoke: tagged-vector print/read asymmetry: %S vs %S"
           v reread))
  (unless (equal (nl-clj-seq reread) '(1 2 3))
    (error "nl-clj-standalone-smoke: read-back vector does not behave as one")))

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
  ;; `tools/ai/nelisp-ai.sh gate NAME -- ...' requires this exact line to
  ;; report what the gate checked; its absence is itself a hard failure
  ;; there (see tools/ai/nelisp-ai.sh's `cmd_gate').
  (princ (format "GATE-COUNT checked=%d findings=%d\n" ran (length failures)))
  (when failures
    (let ((all failures))
      (while all
        (princ (format "FAIL %s\n" (car all)))
        (setq all (cdr all))))
    (error "nl-clj-standalone-smoke: %d failure(s), %d passed"
           (length failures) ran))
  (when (< ran 100)
    (error "nl-clj-standalone-smoke: only %d tests ran (expected >= 100)"
           ran))
  (princ (format "nl-clj-standalone-smoke: PASS (%d tests)\n" ran)))

;;; nl-clj-standalone-smoke.el ends here
