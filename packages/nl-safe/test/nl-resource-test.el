;;; nl-resource-test.el --- ERT tests for nl-resource -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-resource.el' (Doc 170 Stage 3): the type
;; registry, liveness, drop-exactly-once, `nl-forget', scoped ownership
;; through `nl-with-resource' / `nl-with-resources', release ordering,
;; release on non-local exit, the violation log, and the
;; expansion-identity gate for the disable flag (Doc 170 section 9).
;;
;; Like the Stage 1 suite this file avoids cl-lib and ert-x helpers so
;; the same bodies run on `target/nelisp' through the mini harness in
;; `test/nl-resource-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-resource)

;;; Helpers ------------------------------------------------------------

(defvar nl-resource-test--closed nil
  "List of handles released by the test drop function, newest first.")

(defun nl-resource-test--close (handle)
  "Record HANDLE as released and return it."
  (setq nl-resource-test--closed (cons handle nl-resource-test--closed))
  handle)

(defun nl-resource-test--reset ()
  "Clear the release log and register the test resource types."
  (setq nl-resource-test--closed nil)
  (nl-resource-register 'test-fd #'nl-resource-test--close)
  (nl-resource-register 'test-buf #'nl-resource-test--close))

(defun nl-resource-test--fd (n)
  "Return a fresh live `test-fd' resource wrapping N."
  (nl-resource-test--reset)
  (nl-resource 'test-fd n))

;;; Registry -----------------------------------------------------------

(ert-deftest nl-resource-register-round-trip ()
  (nl-resource-test--reset)
  (should (eq (nl-resource-drop-function 'test-fd)
              #'nl-resource-test--close))
  (should-not (nl-resource-drop-function 'no-such-resource-type)))

(ert-deftest nl-resource-register-rejects-bad-arguments ()
  (should-error (nl-resource-register nil #'ignore)
                :type 'nl-resource-error)
  (should-error (nl-resource-register 'test-x 42)
                :type 'nl-resource-error))

(ert-deftest nl-resource-defresource-registers ()
  (nl-defresource nl-resource-test-socket
    :drop #'nl-resource-test--close)
  (should (eq (nl-resource-drop-function 'nl-resource-test-socket)
              #'nl-resource-test--close)))

(ert-deftest nl-resource-defresource-requires-drop ()
  (should-error (macroexpand '(nl-defresource some-type)))
  (should-error (macroexpand '(nl-defresource some-type :close #'ignore))))

;;; Representation -----------------------------------------------------

(ert-deftest nl-resource-p-basics ()
  (nl-resource-test--reset)
  (should (nl-resource-p (nl-resource 'test-fd 3)))
  (should-not (nl-resource-p nil))
  (should-not (nl-resource-p 3))
  (should-not (nl-resource-p (vector 'nl--resource 'test-fd 3)))
  (should-not (nl-resource-p (vector 'other 'test-fd 3 t))))

(ert-deftest nl-resource-unregistered-type-is-refused ()
  (nl-resource-test--reset)
  (should-error (nl-resource 'no-such-resource-type 1)
                :type 'nl-unknown-resource-error))

(ert-deftest nl-resource-accessors ()
  (let ((r (nl-resource-test--fd 7)))
    (should (eq (nl-resource-type r) 'test-fd))
    (should (nl-resource-live-p r))
    (should (= (nl-resource-handle r) 7))
    ;; Drop it: a resource this function acquires and never releases is
    ;; the exact thing `nl-check' reports as resource-untracked, and a
    ;; checker the tree's own tests violate is one nobody will trust.
    (nl-drop r)))

(ert-deftest nl-resource-accessors-reject-non-resources ()
  (should-error (nl-resource-type 5) :type 'nl-resource-error)
  (should-error (nl-resource-live-p nil) :type 'nl-resource-error)
  (should-error (nl-resource-handle "x") :type 'nl-resource-error))

;;; Drop ---------------------------------------------------------------

(ert-deftest nl-resource-drop-runs-drop-function-once ()
  (let ((r (nl-resource-test--fd 11)))
    (should (= (nl-drop r) 11))
    (should (equal nl-resource-test--closed '(11)))
    (should-not (nl-resource-live-p r))))

(ert-deftest nl-resource-double-drop-signals ()
  (let ((r (nl-resource-test--fd 12)))
    (nl-drop r)
    (should-error (nl-drop r) :type 'nl-double-drop-error)
    ;; The failed second drop must not run the drop function again.
    (should (equal nl-resource-test--closed '(12)))))

(ert-deftest nl-resource-handle-after-drop-signals ()
  (let ((r (nl-resource-test--fd 13)))
    (nl-drop r)
    (should-error (nl-resource-handle r) :type 'nl-use-after-drop-error)
    ;; The unchecked reader still reaches the stale handle on purpose.
    (should (= (nl-resource-handle-unchecked r) 13))))

(ert-deftest nl-resource-drop-consumes-even-when-releaser-signals ()
  (nl-resource-test--reset)
  (nl-resource-register 'test-angry
                        (lambda (_h) (error "release failed")))
  (let ((r (nl-resource 'test-angry 1)))
    (should-error (nl-drop r))
    ;; Consumed despite the failure: a releaser that blew up must not
    ;; leave a resource that looks droppable again.
    (should-not (nl-resource-live-p r))
    (should-error (nl-drop r) :type 'nl-double-drop-error)))

;;; Forget -------------------------------------------------------------

(ert-deftest nl-resource-forget-suppresses-drop ()
  (let ((r (nl-resource-test--fd 21)))
    (should (eq (nl-forget r) r))
    (should (equal nl-resource-test--closed nil))
    (should-not (nl-resource-live-p r))))

(ert-deftest nl-resource-forget-twice-signals ()
  (let ((r (nl-resource-test--fd 22)))
    (nl-forget r)
    (should-error (nl-forget r) :type 'nl-double-drop-error)))

(ert-deftest nl-resource-drop-after-forget-signals ()
  (let ((r (nl-resource-test--fd 23)))
    (nl-forget r)
    (should-error (nl-drop r) :type 'nl-double-drop-error)
    (should (equal nl-resource-test--closed nil))))

;;; Scoped ownership ---------------------------------------------------

(ert-deftest nl-resource-with-resource-drops-on-exit ()
  (nl-resource-test--reset)
  (should (= (nl-with-resource (r (nl-resource 'test-fd 31))
               (nl-resource-handle r))
             31))
  (should (equal nl-resource-test--closed '(31))))

(ert-deftest nl-resource-with-resource-drops-on-signal ()
  (nl-resource-test--reset)
  (should-error
   (nl-with-resource (r (nl-resource 'test-fd 32))
     (ignore r)
     (error "boom")))
  (should (equal nl-resource-test--closed '(32))))

(ert-deftest nl-resource-with-resource-drops-on-throw ()
  (nl-resource-test--reset)
  (should (eq (catch 'nl-resource-test-tag
                (nl-with-resource (r (nl-resource 'test-fd 33))
                  (ignore r)
                  (throw 'nl-resource-test-tag 'thrown)))
              'thrown))
  (should (equal nl-resource-test--closed '(33))))

(ert-deftest nl-resource-with-resource-honours-explicit-drop ()
  (nl-resource-test--reset)
  (nl-with-resource (r (nl-resource 'test-fd 34))
    (nl-drop r))
  ;; Exactly one release, not two: the scope exit sees a dead resource.
  (should (equal nl-resource-test--closed '(34))))

(ert-deftest nl-resource-with-resource-honours-forget ()
  (nl-resource-test--reset)
  (nl-with-resource (r (nl-resource 'test-fd 35))
    (nl-forget r))
  (should (equal nl-resource-test--closed nil)))

(ert-deftest nl-resource-with-resource-rejects-bad-binding ()
  (should-error (macroexpand '(nl-with-resource r (ignore r))))
  (should-error (macroexpand '(nl-with-resource (r) (ignore r))))
  (should-error (macroexpand '(nl-with-resource (r 1 2) (ignore r)))))

(ert-deftest nl-resource-with-resources-releases-in-reverse ()
  (nl-resource-test--reset)
  (nl-with-resources ((a (nl-resource 'test-fd 41))
                      (b (nl-resource 'test-buf 42)))
    (should (= (nl-resource-handle a) 41))
    (should (= (nl-resource-handle b) 42)))
  ;; Newest first in the log means 42 was released before 41.
  (should (equal nl-resource-test--closed '(41 42))))

(ert-deftest nl-resource-with-resources-inits-see-earlier-bindings ()
  (nl-resource-test--reset)
  (nl-with-resources ((a (nl-resource 'test-fd 5))
                      (b (nl-resource 'test-buf
                                      (* 2 (nl-resource-handle a)))))
    (should (= (nl-resource-handle b) 10)))
  (should (equal nl-resource-test--closed '(5 10))))

(ert-deftest nl-resource-with-resources-empty-is-progn ()
  (should (= (nl-with-resources () 1 2 3) 3)))

;;; Violation log ------------------------------------------------------

(ert-deftest nl-resource-double-drop-is-logged ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (r (nl-resource-test--fd 51)))
    (nl-drop r)
    (should-error (nl-drop r) :type 'nl-double-drop-error)
    (should (= (length nl-safe--violation-log) 1))
    (let ((record (car nl-safe--violation-log)))
      (should (eq (plist-get record :kind) 'resource))
      (should (eq (plist-get record :violation) 'double-drop))
      (should (eq (plist-get record :type) 'test-fd)))))

(ert-deftest nl-resource-use-after-drop-is-logged ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (r (nl-resource-test--fd 52)))
    (nl-drop r)
    (should-error (nl-resource-handle r) :type 'nl-use-after-drop-error)
    (should (eq (plist-get (car nl-safe--violation-log) :violation)
                'use-after-drop))))

(ert-deftest nl-resource-clean-run-logs-nothing ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil))
    (nl-resource-test--reset)
    (nl-with-resource (r (nl-resource 'test-fd 53))
      (nl-resource-handle r))
    (should-not nl-safe--violation-log)))

;;; Disable flag (expansion identity, Doc 170 section 9) ---------------

(ert-deftest nl-resource-disabled-expansion-has-no-liveness-check ()
  (let* ((form '(nl-with-resource (r (nl-resource 'test-fd 1))
                  (nl-resource-handle-unchecked r)))
         (checked (let ((nl-safe--enabled t)) (macroexpand form)))
         (plain (let ((nl-safe--enabled nil)) (macroexpand form))))
    (should-not (equal checked plain))
    (should (equal plain
                   '(let ((r (nl-resource 'test-fd 1)))
                      (unwind-protect
                          (progn (nl-resource-handle-unchecked r))
                        (nl-resource--drop-unchecked r)))))))

(ert-deftest nl-resource-disabled-expansion-still-releases ()
  (nl-resource-test--reset)
  (let ((nl-safe--enabled nil))
    (eval '(nl-with-resource (r (nl-resource 'test-fd 61))
             (nl-resource-handle-unchecked r))
          t))
  (should (equal nl-resource-test--closed '(61))))

(provide 'nl-resource-test)

;;; nl-resource-test.el ends here
