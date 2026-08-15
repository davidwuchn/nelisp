;;; nl-resource.el --- Deterministic resource drop for NeLisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 Stage 3: resource ownership and deterministic drop.  Where
;; Stage 1 covers aliasing (`nl-cell') and memory (fat pointers), this
;; file covers the third safety axis of Doc 170 section 1: *resource*
;; safety -- forgetting to release, and releasing twice.
;;
;; Public API:
;;
;;   Registry:     `nl-defresource' `nl-resource-register'
;;                 `nl-resource-drop-function'
;;   Values:       `nl-resource' `nl-resource-p' `nl-resource-type'
;;                 `nl-resource-live-p' `nl-resource-handle'
;;   Consumption:  `nl-drop' `nl-forget'
;;   Scoped:       `nl-with-resource' `nl-with-resources'
;;
;; Representation: [nl--resource TYPE HANDLE LIVE], LIVE is t until the
;; value is consumed by `nl-drop' or `nl-forget'.  The flag is what
;; turns "double free" and "use after free" from silent corruption in
;; the runtime layer into a signaled `nl-resource-error'.
;;
;; Rust correspondence: `nl-defresource' :drop is `Drop::drop',
;; `nl-with-resource' is a lexical owner (drop at scope exit, also on
;; `signal' and `throw' because the expansion is `unwind-protect'), and
;; `nl-forget' is `mem::forget' -- it suppresses the drop, so it is the
;; one operation here that can leak on purpose.
;;
;; Disable flag (Doc 170 section 9): when `nl-safe--enabled' is nil at
;; macro-expansion time, `nl-with-resource' expands to a plain
;; `unwind-protect' that calls the drop function directly, with none of
;; the liveness bookkeeping.  Same rule as the Stage 1 macros: the flag
;; is read at expansion time, so flip it at top level.
;;
;; Violations are recorded through `nl-safe--log-violation' with
;; `:kind' `resource', so they land in the same `nl-safe--violation-log'
;; that feeds the Doc 168 Phase 6 go/no-go gate.
;;
;; Design constraints:
;;   - pure Lisp, depends only on nl-prelude and nl-safe
;;   - must run unchanged on `target/nelisp' standalone (no ert there;
;;     see test/nl-resource-standalone-smoke.el)

;;; Code:

(require 'nl-prelude)
(require 'nl-safe)

;;;; Errors -----------------------------------------------------------

(define-error 'nl-resource-error "Resource protocol violation" 'nl-error)
(define-error 'nl-double-drop-error
              "Resource dropped twice" 'nl-resource-error)
(define-error 'nl-use-after-drop-error
              "Resource used after drop" 'nl-resource-error)
(define-error 'nl-unknown-resource-error
              "Resource type is not registered" 'nl-resource-error)

;;;; Registry ---------------------------------------------------------

(defvar nl-resource--drops (make-hash-table :test 'eq)
  "Map of resource TYPE symbol -> drop function of one argument.
The drop function receives the raw handle, never the wrapper.")

(defun nl-resource-register (type drop-function)
  "Register DROP-FUNCTION as the releaser for resource TYPE.
DROP-FUNCTION is called with the raw handle exactly once, when the
resource is consumed.  Re-registering TYPE replaces the previous
function; that is deliberate so a file can be reloaded during
development without restarting."
  (unless (and type (symbolp type))
    (signal 'nl-resource-error (list "TYPE must be a non-nil symbol" type)))
  (unless (functionp drop-function)
    (signal 'nl-resource-error
            (list "drop must be a function" type drop-function)))
  (puthash type drop-function nl-resource--drops)
  type)

(defun nl-resource-drop-function (type)
  "Return the drop function registered for TYPE, or nil when absent."
  (gethash type nl-resource--drops))

(defmacro nl-defresource (name &rest properties)
  "Declare NAME as a resource type with PROPERTIES.
Only `:drop FUNCTION' is recognised; it is required.  The drop
function takes the raw handle.

  (nl-defresource file-handle :drop (lambda (fd) (nl-close fd)))
  (nl-with-resource (fd (nl-resource \\='file-handle (nl-open path)))
    (nl-read (nl-resource-handle fd) 100))"
  (declare (indent defun))
  (unless (and name (symbolp name))
    (error "nl-defresource: NAME must be a non-nil symbol, got %S" name))
  (let ((drop (plist-get properties :drop))
        (unknown nil)
        (tail properties))
    (while tail
      (unless (eq (car tail) :drop)
        (setq unknown (cons (car tail) unknown)))
      (setq tail (cdr (cdr tail))))
    (when unknown
      (error "nl-defresource: unknown properties %S" (nreverse unknown)))
    (unless drop
      (error "nl-defresource: %s needs a :drop function" name))
    `(nl-resource-register ',name ,drop)))

;;;; Representation ---------------------------------------------------

(defun nl-resource (type handle)
  "Wrap HANDLE as a live resource of TYPE.
Signals `nl-unknown-resource-error' when TYPE has no registered drop
function: a resource nobody can release is a leak by construction, so
it is refused at the point where it is cheap to diagnose."
  (unless (nl-resource-drop-function type)
    (signal 'nl-unknown-resource-error (list type)))
  (vector 'nl--resource type handle t))

(defun nl-resource-p (object)
  "Return non-nil when OBJECT is a resource wrapper."
  (and (vectorp object)
       (= (length object) 4)
       (eq (aref object 0) 'nl--resource)))

(defun nl-resource--check (object operation)
  "Signal unless OBJECT is a resource; OPERATION names the caller."
  (unless (nl-resource-p object)
    (signal 'nl-resource-error (list operation "not a resource" object)))
  object)

(defun nl-resource-type (resource)
  "Return the type symbol of RESOURCE."
  (aref (nl-resource--check resource 'nl-resource-type) 1))

(defun nl-resource-live-p (resource)
  "Return non-nil when RESOURCE has not been consumed yet."
  (aref (nl-resource--check resource 'nl-resource-live-p) 3))

(defun nl-resource-handle (resource)
  "Return the raw handle inside RESOURCE.
Signals `nl-use-after-drop-error' when RESOURCE was already consumed;
that signal is the whole point of the wrapper, since a stale fd or
mmap address is exactly the value that corrupts silently."
  (nl-resource--check resource 'nl-resource-handle)
  (unless (aref resource 3)
    (nl-safe--log-violation
     (list :kind 'resource :violation 'use-after-drop
           :type (aref resource 1)))
    (signal 'nl-use-after-drop-error (list (aref resource 1))))
  (aref resource 2))

(defun nl-resource-handle-unchecked (resource)
  "Return the raw handle inside RESOURCE without a liveness check.
Used by the unchecked expansions when `nl-safe--enabled' is nil, and
by drop functions that legitimately run during consumption."
  (aref (nl-resource--check resource 'nl-resource-handle-unchecked) 2))

;;;; Consumption ------------------------------------------------------

(defun nl-drop (resource)
  "Release RESOURCE by running its drop function, exactly once.
Returns the drop function's value.  Signals `nl-double-drop-error'
when RESOURCE was already consumed.  The liveness flag is cleared
BEFORE the drop function runs, so a drop function that itself signals
still leaves the resource consumed rather than droppable again."
  (nl-resource--check resource 'nl-drop)
  (unless (aref resource 3)
    (nl-safe--log-violation
     (list :kind 'resource :violation 'double-drop
           :type (aref resource 1)))
    (signal 'nl-double-drop-error (list (aref resource 1))))
  (let ((drop (nl-resource-drop-function (aref resource 1))))
    (unless drop
      (signal 'nl-unknown-resource-error (list (aref resource 1))))
    (aset resource 3 nil)
    (funcall drop (aref resource 2))))

(defun nl-forget (resource)
  "Consume RESOURCE without running its drop function.
The Elisp counterpart of Rust's `mem::forget': it suppresses the
release, so the underlying handle leaks on purpose.  Use it only when
ownership moved somewhere this library cannot see -- a foreign
callee, or a handle deliberately inherited across `exec'.  Signals
`nl-double-drop-error' when RESOURCE was already consumed."
  (nl-resource--check resource 'nl-forget)
  (unless (aref resource 3)
    (nl-safe--log-violation
     (list :kind 'resource :violation 'double-drop
           :type (aref resource 1)))
    (signal 'nl-double-drop-error (list (aref resource 1))))
  (aset resource 3 nil)
  resource)

(defun nl-resource--drop-unchecked (resource)
  "Run RESOURCE's drop function with no liveness bookkeeping.
The unchecked counterpart of `nl-drop', used by the disabled
expansion of `nl-with-resource' (Doc 170 section 9)."
  (funcall (nl-resource-drop-function (aref resource 1))
           (aref resource 2)))

;;;; Scoped ownership -------------------------------------------------

(defmacro nl-with-resource (binding &rest body)
  "Evaluate BODY with BINDING owned, dropping it on scope exit.
BINDING is (VAR INIT) where INIT evaluates to a resource.  VAR is
dropped when BODY leaves, including on `signal' and `throw', and is
NOT dropped again if BODY consumed it explicitly with `nl-drop' or
`nl-forget'.

When `nl-safe--enabled' is nil at expansion time the liveness check is
omitted and the drop function is called directly."
  (declare (indent 1))
  (unless (and (consp binding) (symbolp (car binding))
               (consp (cdr binding)) (null (cdr (cdr binding))))
    (error "nl-with-resource: BINDING must be (VAR INIT), got %S" binding))
  (let ((var (car binding))
        (init (car (cdr binding))))
    (if nl-safe--enabled
        `(let ((,var ,init))
           (unwind-protect
               (progn ,@body)
             (when (nl-resource-live-p ,var)
               (nl-drop ,var))))
      `(let ((,var ,init))
         (unwind-protect
             (progn ,@body)
           (nl-resource--drop-unchecked ,var))))))

(defmacro nl-with-resources (bindings &rest body)
  "Evaluate BODY with each of BINDINGS owned, dropping in reverse order.
BINDINGS is a list of (VAR INIT) forms; each INIT sees the previous
bindings, like `let*'.  Expands to nested `nl-with-resource', so the
last acquired resource is released first."
  (declare (indent 1))
  (if (null bindings)
      `(progn ,@body)
    `(nl-with-resource ,(car bindings)
       (nl-with-resources ,(cdr bindings) ,@body))))

(provide 'nl-resource)

;;; nl-resource.el ends here
