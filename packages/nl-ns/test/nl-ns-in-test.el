;;; nl-ns-in-test.el --- ERT tests for nl-ns-in -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-ns-in.el': the registry, the resolution rule
;; (defined-here and not lexically bound), shadowing through every
;; binding form the walker models, what is deliberately left alone
;; (quoted data, foreign names), and end-to-end evaluation.
;;
;; The shadowing tests carry the weight.  A namespace macro that
;; rewrites a `let' variable because it happens to share a name with a
;; member is worse than no namespace macro, so each binder gets an
;; explicit test.
;;
;; No cl-lib, no ert-x, so the bodies also run under the standalone
;; harness.

;;; Code:

(require 'ert)
(require 'nl-ns-in)

;;; Helpers ------------------------------------------------------------

(defun nl-ns-in-test--reset ()
  "Start from a clean registry with namespace `tns' defined."
  (nl-ns-clear-namespaces)
  (eval '(nl-ns-define tns) t))

(defun nl-ns-in-test--expand (body)
  "Expand BODY in namespace `tns' after resetting the registry."
  (nl-ns-in-test--reset)
  (nl-ns-expand 'tns body))

;;; Registry ------------------------------------------------------------

(ert-deftest nl-ns-in-define-sets-default-prefix ()
  (nl-ns-in-test--reset)
  (should (equal (nl-ns-prefix 'tns) "tns-")))

(ert-deftest nl-ns-in-define-accepts-explicit-prefix ()
  (nl-ns-clear-namespaces)
  (eval '(nl-ns-define tns :prefix "t/") t)
  (should (equal (nl-ns-prefix 'tns) "t/"))
  (should (eq (nl-ns-qualify 'tns 'foo) 't/foo)))

(ert-deftest nl-ns-in-define-rejects-bad-input ()
  (should-error (macroexpand '(nl-ns-define "tns")))
  (should-error (macroexpand '(nl-ns-define tns :prefix sym)))
  (should-error (macroexpand '(nl-ns-define tns :suffix "x"))))

(ert-deftest nl-ns-in-undefined-namespace-signals ()
  (nl-ns-clear-namespaces)
  (should-error (nl-ns-prefix 'no-such-namespace)))

(ert-deftest nl-ns-in-members-accumulate ()
  (nl-ns-in-test--reset)
  (eval '(nl-ns-members tns alpha beta) t)
  (should (equal (nl-ns-member-list 'tns) '(alpha beta)))
  ;; Declaring the same member twice does not duplicate it.
  (eval '(nl-ns-members tns alpha) t)
  (should (equal (nl-ns-member-list 'tns) '(alpha beta))))

(ert-deftest nl-ns-in-qualify ()
  (nl-ns-in-test--reset)
  (should (eq (nl-ns-qualify 'tns 'wrap) 'tns-wrap)))

;;; The resolution rule --------------------------------------------------

(ert-deftest nl-ns-in-renames-definitions ()
  (should (equal (nl-ns-in-test--expand '((defun wrap (s) s)))
                 '((defun tns-wrap (s) s)))))

(ert-deftest nl-ns-in-renames-calls-to-block-members ()
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (s) (chunk s))
                    (defun chunk (s) s)))
                 '((defun tns-wrap (s) (tns-chunk s))
                   (defun tns-chunk (s) s)))))

(ert-deftest nl-ns-in-renames-variables ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (s) (substring s 0 limit))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (s) (substring s 0 tns-limit))))))

(ert-deftest nl-ns-in-leaves-foreign-names-alone ()
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (s) (mapcar #'car (substring s 0 1)))))
                 '((defun tns-wrap (s) (mapcar #'car (substring s 0 1)))))))

(ert-deftest nl-ns-in-uses-declared-members ()
  (nl-ns-in-test--reset)
  (eval '(nl-ns-members tns helper) t)
  ;; `helper' is defined by another block, so it resolves here too.
  (should (equal (nl-ns-expand 'tns '((defun wrap (s) (helper s))))
                 '((defun tns-wrap (s) (tns-helper s))))))

(ert-deftest nl-ns-in-forward-reference-within-a-block ()
  ;; `chunk' is used before it is defined; the scan is done first, so
  ;; order inside the block does not matter.
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (s) (chunk s))
                    (defun chunk (s) s)))
                 '((defun tns-wrap (s) (tns-chunk s))
                   (defun tns-chunk (s) s)))))

;;; Quoted data is not rewritten -----------------------------------------

(ert-deftest nl-ns-in-leaves-quoted-symbols-alone ()
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (s) (list 'chunk s))
                    (defun chunk (s) s)))
                 '((defun tns-wrap (s) (list 'chunk s))
                   (defun tns-chunk (s) s)))))

(ert-deftest nl-ns-in-rewrites-sharp-quoted-function-refs ()
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (l) (mapcar #'chunk l))
                    (defun chunk (s) s)))
                 '((defun tns-wrap (l) (mapcar #'tns-chunk l))
                   (defun tns-chunk (s) s)))))

(ert-deftest nl-ns-in-rewrites-inside-sharp-quoted-lambda ()
  (should (equal (nl-ns-in-test--expand
                  '((defun wrap (l) (mapcar (lambda (x) (chunk x)) l))
                    (defun chunk (s) s)))
                 '((defun tns-wrap (l) (mapcar (lambda (x) (tns-chunk x)) l))
                   (defun tns-chunk (s) s)))))

;;; Shadowing -------------------------------------------------------------

(ert-deftest nl-ns-in-let-shadows-a-member ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (s) (let ((limit 5)) (substring s 0 limit)))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (s)
                     (let ((limit 5)) (substring s 0 limit)))))))

(ert-deftest nl-ns-in-let-init-is-outer-scope ()
  ;; In plain `let' the init sees the OUTER binding, so it is rewritten.
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap () (let ((limit limit)) limit))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap () (let ((limit tns-limit)) limit))))))

(ert-deftest nl-ns-in-let-star-init-sees-previous-bindings ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap () (let* ((limit 5) (n limit)) n))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap () (let* ((limit 5) (n limit)) n))))))

(ert-deftest nl-ns-in-lambda-argument-shadows ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap () (lambda (limit) limit))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap () (lambda (limit) limit))))))

(ert-deftest nl-ns-in-defun-argument-shadows ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (limit) limit)))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (limit) limit)))))

(ert-deftest nl-ns-in-defun-optional-marker-is-not-a-variable ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (&optional limit) limit)))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (&optional limit) limit)))))

(ert-deftest nl-ns-in-defun-optional-spec-vars-shadow ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (&optional (limit 1 supplied))
                      (list limit supplied))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (&optional (limit 1 supplied))
                     (list limit supplied))))))

(ert-deftest nl-ns-in-defun-default-is-outer-scope ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (&optional (n limit)) n)))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (&optional (n tns-limit)) n)))))

(ert-deftest nl-ns-in-dolist-variable-shadows ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (l) (dolist (limit l) limit))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (l) (dolist (limit l) limit))))))

(ert-deftest nl-ns-in-dolist-list-form-is-rewritten ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar items nil)
                    (defun wrap () (dolist (x items) x))))
                 '((defvar tns-items nil)
                   (defun tns-wrap () (dolist (x tns-items) x))))))

(ert-deftest nl-ns-in-dolist-result-sees-loop-variable ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap (l) (dolist (limit l limit) nil))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap (l) (dolist (limit l limit) nil))))))

(ert-deftest nl-ns-in-dotimes-result-sees-loop-variable ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar limit 80)
                    (defun wrap () (dotimes (limit 3 limit) limit))))
                 '((defvar tns-limit 80)
                   (defun tns-wrap () (dotimes (limit 3 limit) limit))))))

(ert-deftest nl-ns-in-condition-case-variable-shadows ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar err 1)
                    (defun wrap () (condition-case err (f) (error err)))))
                 '((defvar tns-err 1)
                   (defun tns-wrap ()
                     (condition-case err (f) (error err)))))))

(ert-deftest nl-ns-in-condition-case-protected-form-is-outer-scope ()
  (should (equal (nl-ns-in-test--expand
                  '((defvar err 1)
                    (defun wrap ()
                      (condition-case err err (error err)))))
                 '((defvar tns-err 1)
                   (defun tns-wrap ()
                     (condition-case err tns-err (error err)))))))

;;; End to end ------------------------------------------------------------

(ert-deftest nl-ns-in-defines-qualified-functions ()
  (nl-ns-in-test--reset)
  (eval '(nl-ns-in tns
           (defvar limit 3)
           (defun chunk (s) (substring s 0 limit))
           (defun wrap (s) (chunk s)))
        t)
  (should (fboundp 'tns-wrap))
  (should (fboundp 'tns-chunk))
  (should (boundp 'tns-limit))
  (should-not (fboundp 'wrap))
  (should (equal (funcall 'tns-wrap "abcdef") "abc")))

(ert-deftest nl-ns-in-registers-members-for-later-blocks ()
  (nl-ns-in-test--reset)
  (eval '(nl-ns-in tns (defun helper (x) (* x 2))) t)
  ;; A second block resolves `helper' because the first block declared it.
  (should (equal (nl-ns-expand 'tns '((defun use (x) (helper x))))
                 '((defun tns-use (x) (tns-helper x))))))

(ert-deftest nl-ns-in-requires-a-defined-namespace ()
  (nl-ns-clear-namespaces)
  (should-error (macroexpand '(nl-ns-in nowhere (defun f () 1)))))

(ert-deftest nl-ns-in-empty-body-is-progn ()
  (nl-ns-in-test--reset)
  (should (equal (macroexpand '(nl-ns-in tns)) '(progn))))

(provide 'nl-ns-in-test)

;;; nl-ns-in-test.el ends here
