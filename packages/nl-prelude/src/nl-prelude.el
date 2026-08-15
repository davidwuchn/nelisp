;;; nl-prelude.el --- Result/Option error handling for NeLisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 169 (nl-prelude / nl-condition) Phase 1: value-based error
;; handling for Elisp code running on NeLisp (or host Emacs).
;;
;; Public API (Phase 1 scope is locked to Result / Option / `nl-?'):
;;
;;   Construction:  `nl-ok' `nl-err' `nl-some' `nl-none'
;;   Predicates:    `nl-ok-p' `nl-err-p' `nl-result-p'
;;                  `nl-some-p' `nl-none-p' `nl-option-p'
;;   Extraction:    `nl-unwrap' `nl-unwrap-or' `nl-unwrap-or-else'
;;   Transform:     `nl-map' `nl-map-err' `nl-and-then'
;;                  `nl-ok->option' `nl-option->ok'
;;   Aggregation:   `nl-collect'
;;   Early return:  `nl-?' inside `nl-defun' / `nl-lambda' (+ `nl-let*')
;;
;; Representation (Doc 169 section 2.1): tagged conses, not cl-defstruct.
;;
;;   Result: (nl--ok . VALUE) / (nl--err . ERROR)
;;   Option: (nl--some . VALUE) / nl--none
;;
;; Tags are interned symbols compared with `eq'.
;;
;; `nl-?' constraints (Doc 169 section 2.3, enforced at expansion time):
;;   - using `nl-?' outside `nl-defun' / `nl-lambda' is an expansion
;;     error, not a runtime `cl-return-from' failure
;;   - `nl-?' must not cross a nested plain `lambda'; such uses are
;;     rejected when the enclosing `nl-defun' / `nl-lambda' expands.
;;     A nested `nl-lambda' / `nl-defun' opens its own return block.
;;
;; The rejection walker inspects the unexpanded body, so `nl-?' forms
;; produced by other macros inside the body are not seen.  This is a
;; documented v0.1 limitation (see README.org).
;;
;; Design constraints:
;;   - pure Lisp only, no dependency beyond core + cl-lib macros
;;   - must run unchanged on `target/nelisp' standalone (no ert there;
;;     see test/nl-prelude-standalone-smoke.el)

;;; Code:

(require 'cl-lib)

;;;; Errors -----------------------------------------------------------

(define-error 'nl-error "nl-prelude error")
(define-error 'nl-unwrap-error "Unwrap of an err/none value" 'nl-error)
(define-error 'nl-type-error "Value is not a Result/Option" 'nl-error)

;;;; Representation ---------------------------------------------------

(defconst nl-none 'nl--none
  "The Option none value (Doc 169 section 2.1).")

(defun nl-ok (value)
  "Wrap VALUE as a successful Result."
  (cons 'nl--ok value))

(defun nl-err (error)
  "Wrap ERROR as a failed Result."
  (cons 'nl--err error))

(defun nl-some (value)
  "Wrap VALUE as a present Option."
  (cons 'nl--some value))

;;;; Predicates -------------------------------------------------------

(defun nl-ok-p (object)
  "Return non-nil when OBJECT is an ok Result."
  (eq (car-safe object) 'nl--ok))

(defun nl-err-p (object)
  "Return non-nil when OBJECT is an err Result."
  (eq (car-safe object) 'nl--err))

(defun nl-result-p (object)
  "Return non-nil when OBJECT is a Result (ok or err)."
  (or (nl-ok-p object) (nl-err-p object)))

(defun nl-some-p (object)
  "Return non-nil when OBJECT is a some Option."
  (eq (car-safe object) 'nl--some))

(defun nl-none-p (object)
  "Return non-nil when OBJECT is the none Option."
  (eq object 'nl--none))

(defun nl-option-p (object)
  "Return non-nil when OBJECT is an Option (some or none)."
  (or (nl-some-p object) (nl-none-p object)))

;;;; Internal helpers -------------------------------------------------

(defun nl--payload-or-signal (object caller)
  "Validate OBJECT as Result/Option for CALLER; return its kind symbol.
The kind is one of `ok', `err', `some', `none'.  Signal `nl-type-error'
when OBJECT is neither a Result nor an Option."
  (cond ((nl-ok-p object) 'ok)
        ((nl-err-p object) 'err)
        ((nl-some-p object) 'some)
        ((nl-none-p object) 'none)
        (t (signal 'nl-type-error (list caller object)))))

;;;; Extraction -------------------------------------------------------

(defun nl-unwrap (result)
  "Return the value inside an ok/some RESULT.
Signal `nl-unwrap-error' on an err Result (with the err payload) or on
none.  Signal `nl-type-error' when RESULT is not a Result/Option."
  (pcase (nl--payload-or-signal result 'nl-unwrap)
    ((or 'ok 'some) (cdr result))
    ('err (signal 'nl-unwrap-error (list (cdr result))))
    ('none (signal 'nl-unwrap-error (list 'nl--none)))))

(defun nl-unwrap-or (result default)
  "Return the value inside an ok/some RESULT, else DEFAULT."
  (pcase (nl--payload-or-signal result 'nl-unwrap-or)
    ((or 'ok 'some) (cdr result))
    (_ default)))

(defun nl-unwrap-or-else (result fn)
  "Return the value inside an ok/some RESULT, else call FN.
On an err Result, FN receives the err payload; on none, FN receives no
arguments."
  (pcase (nl--payload-or-signal result 'nl-unwrap-or-else)
    ((or 'ok 'some) (cdr result))
    ('err (funcall fn (cdr result)))
    ('none (funcall fn))))

;;;; Transform --------------------------------------------------------

(defun nl-map (result fn)
  "Apply FN to the value inside an ok/some RESULT.
Return a Result/Option of the same kind.  err and none pass through
unchanged (the identical object)."
  (pcase (nl--payload-or-signal result 'nl-map)
    ('ok (nl-ok (funcall fn (cdr result))))
    ('some (nl-some (funcall fn (cdr result))))
    (_ result)))

(defun nl-map-err (result fn)
  "Apply FN to the error inside an err RESULT.
ok passes through unchanged.  RESULT must be a Result."
  (pcase (nl--payload-or-signal result 'nl-map-err)
    ('err (nl-err (funcall fn (cdr result))))
    ('ok result)
    (_ (signal 'nl-type-error (list 'nl-map-err result)))))

(defun nl-and-then (result fn)
  "Monadic bind: call FN on the value inside an ok/some RESULT.
FN must itself return a Result (for ok input) or an Option (for some
input).  err and none short-circuit: they are returned unchanged and FN
is not called."
  (pcase (nl--payload-or-signal result 'nl-and-then)
    ((or 'ok 'some) (funcall fn (cdr result)))
    (_ result)))

(defun nl-ok->option (result)
  "Convert a Result to an Option: ok -> some, err -> none (payload dropped)."
  (pcase (nl--payload-or-signal result 'nl-ok->option)
    ('ok (nl-some (cdr result)))
    ('err nl-none)
    (_ (signal 'nl-type-error (list 'nl-ok->option result)))))

(defun nl-option->ok (option error)
  "Convert an Option to a Result: some -> ok, none -> (nl-err ERROR)."
  (pcase (nl--payload-or-signal option 'nl-option->ok)
    ('some (nl-ok (cdr option)))
    ('none (nl-err error))
    (_ (signal 'nl-type-error (list 'nl-option->ok option)))))

;;;; Aggregation ------------------------------------------------------

(defun nl-collect (results)
  "Collect a list of Results into one Result.
When every element of RESULTS is ok, return (nl-ok LIST-OF-VALUES) in
order.  Return the first err encountered unchanged, without inspecting
the remaining elements (short-circuit)."
  (let ((acc nil)
        (rest results)
        (ret nil))
    (while (and rest (not ret))
      (let ((r (car rest)))
        (cond ((nl-err-p r) (setq ret r))
              ((nl-ok-p r) (push (cdr r) acc))
              (t (signal 'nl-type-error (list 'nl-collect r)))))
      (setq rest (cdr rest)))
    (or ret (nl-ok (nreverse acc)))))

;;;; nl-? early return ------------------------------------------------

(defmacro nl-? (_form)
  "Early-return operator for Result values (Doc 169 section 2.3).
Valid only inside the body of `nl-defun' / `nl-lambda', where the
enclosing macro rewrites it.  Reaching this global definition means the
constraint was violated, so expansion fails loudly instead of leaving a
runtime `cl-return-from' error behind."
  (error "nl-?: only valid inside the body of `nl-defun' or `nl-lambda'"))

(defun nl--expand-? (form in-lambda)
  "Rewrite (nl-? X) forms inside FORM for the enclosing return block.
IN-LAMBDA non-nil means FORM sits inside a nested plain `lambda'; any
`nl-?' found there is rejected at expansion time.  Nested `nl-defun' /
`nl-lambda' forms are left untouched -- they open their own block when
they expand.  Quoted forms are not descended into."
  (cond
   ((not (consp form)) form)
   ((eq (car form) 'quote) form)
   ((eq (car form) 'nl-?)
    (when in-lambda
      (error "nl-?: must not cross a nested `lambda' boundary"))
    (unless (and (consp (cdr form)) (null (cddr form)))
      (error "nl-?: expects exactly one form, got %S" form))
    (let ((r (gensym "nl--r"))
          (inner (nl--expand-? (cadr form) in-lambda)))
      `(let ((,r ,inner))
         (cond ((nl-err-p ,r) (cl-return-from nl--fn-block ,r))
               ((nl-ok-p ,r) (cdr ,r))
               (t (signal 'nl-type-error (list 'nl-? ,r)))))))
   ((memq (car form) '(nl-defun nl-lambda))
    form)
   ((eq (car form) 'lambda)
    (nl--expand-?-seq form t))
   ((and (eq (car form) 'function)
         (eq (car-safe (car-safe (cdr form))) 'lambda))
    (nl--expand-?-seq form t))
   (t (nl--expand-?-seq form in-lambda))))

(defun nl--expand-?-seq (form in-lambda)
  "Map `nl--expand-?' over the cons tree FORM, preserving dotted tails.
IN-LAMBDA is passed through to `nl--expand-?'."
  (if (consp form)
      (cons (nl--expand-? (car form) in-lambda)
            (nl--expand-?-seq (cdr form) in-lambda))
    form))

(defun nl--wrap-?-body (body)
  "Wrap BODY forms in the `nl-?' return block.
Return a list whose head keeps any leading docstring / `declare' /
`interactive' forms outside the block."
  (let ((prefix nil))
    (when (and (stringp (car body)) (cdr body))
      (push (pop body) prefix))
    (while (and (consp (car body))
                (memq (caar body) '(declare interactive)))
      (push (pop body) prefix))
    (append (nreverse prefix)
            `((cl-block nl--fn-block
                ,@(mapcar (lambda (f) (nl--expand-? f nil)) body))))))

(defmacro nl-defun (name arglist &rest body)
  "Define NAME as a function whose BODY may use `nl-?'.
ARGLIST is a normal `defun' argument list.  The body runs inside a
return block: (nl-? R) unwraps an ok Result R inline and early-returns
an err R from the whole function."
  (declare (indent defun) (doc-string 3))
  `(defun ,name ,arglist
     ,@(nl--wrap-?-body body)))

(defmacro nl-lambda (arglist &rest body)
  "Return an anonymous function whose BODY may use `nl-?'.
ARGLIST is a normal `lambda' argument list.  See `nl-defun'."
  (declare (indent defun))
  `(lambda ,arglist
     ,@(nl--wrap-?-body body)))

(defmacro nl-let* (bindings &rest body)
  "Sequential `let*' spelled for `nl-?' pipelines (Doc 169 section 2.3).
BINDINGS and BODY behave exactly like `let*'; this alias only marks
intent in code written against the nl-prelude API."
  (declare (indent 1))
  `(let* ,bindings ,@body))

(provide 'nl-prelude)

;;; nl-prelude.el ends here