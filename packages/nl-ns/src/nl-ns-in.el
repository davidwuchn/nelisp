;;; nl-ns-in.el --- A namespace you can actually write in -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The writing half of nl-ns.  A namespace has a closed, declared member
;; set, so expanding one block never depends on another block's expansion.
;;
;;   (nl-ns-define text :members (limit wrap chunk))
;;   (nl-ns-in text
;;     (defvar limit 80)
;;     (defun wrap (s) (chunk s limit))
;;     (defun chunk (s n) (substring s 0 n)))
;;
;; defines text-limit, text-wrap, and text-chunk.

;;; Code:

(require 'nl-prelude)

;;;; Registry -----------------------------------------------------------

(defvar nl-ns--namespaces (make-hash-table :test 'eq)
  "Map of namespace symbol -> plist (:prefix STRING :members LIST).")

(defun nl-ns-clear-namespaces ()
  "Forget every `nl-ns-define' declaration."
  (clrhash nl-ns--namespaces)
  nil)

(defun nl-ns--entry (name)
  "Return the registry entry for NAME, signalling when it is absent."
  (or (gethash name nl-ns--namespaces)
      (error "nl-ns: namespace `%s' is not defined; call nl-ns-define first"
             name)))

(defmacro nl-ns-define (name &rest properties)
  "Declare NAME as a namespace with a closed `:members' set.
PROPERTIES accepts `:prefix STRING', defaulting to \"NAME-\", and
`:members (SYMBOL...)'.  Re-defining a namespace replaces its declaration."
  (unless (and name (symbolp name))
    (error "nl-ns-define: NAME must be a non-nil symbol, got %S" name))
  (let ((prefix (plist-get properties :prefix))
        (members (plist-get properties :members))
        (unknown nil)
        (tail properties))
    (while tail
      (unless (memq (car tail) '(:prefix :members))
        (setq unknown (cons (car tail) unknown)))
      (setq tail (cdr (cdr tail))))
    (when unknown
      (error "nl-ns-define: unknown properties %S" (nreverse unknown)))
    (when (and prefix (not (stringp prefix)))
      (error "nl-ns-define: :prefix must be a string, got %S" prefix))
    (unless (listp members)
      (error "nl-ns-define: :members must be a list, got %S" members))
    (dolist (member members)
      (unless (symbolp member)
        (error "nl-ns-define: :members must contain symbols, got %S" member)))
    `(eval-and-compile
       (puthash ',name
                (list :prefix ,(or prefix (concat (symbol-name name) "-"))
                      :members ',members)
                nl-ns--namespaces)
       ',name)))

(defun nl-ns-prefix (name)
  "Return the prefix string of namespace NAME."
  (plist-get (nl-ns--entry name) :prefix))

(defun nl-ns-member-list (name)
  "Return the declared member symbols of namespace NAME, in order."
  (plist-get (nl-ns--entry name) :members))

(defun nl-ns-qualify (name symbol)
  "Return SYMBOL prefixed with namespace NAME's prefix."
  (intern (concat (nl-ns-prefix name) (symbol-name symbol))))

;;;; Rewriting -----------------------------------------------------------

(define-error 'nl-ns-in-non-member-error
  "nl-ns-in definition names an undeclared namespace member" 'nl-error)
(define-error 'nl-ns-in-member-binding-error
  "nl-ns-in binding shadows a namespace member" 'nl-error)

(defconst nl-ns-in-definition-heads
  '(defun defmacro defsubst defvar defconst defcustom cl-defun cl-defmacro)
  "Heads whose second element `nl-ns-in' treats as a definition to rename.")

(defun nl-ns-in--arglist-vars (arglist)
  "Return the variables ARGLIST binds, skipping lambda-list markers."
  (let ((out nil))
    (dolist (arg (if (listp arglist) arglist nil))
      (cond
       ((and (symbolp arg) arg
             (not (eq (aref (symbol-name arg) 0) ?&)))
        (setq out (cons arg out)))
       ((consp arg)
        (let ((var (car arg)) (supplied (car (cdr (cdr arg)))))
          (when (and (consp var) (symbolp (car (cdr var))))
            (setq var (car (cdr var))))
          (when (symbolp var) (setq out (cons var out)))
          (when (symbolp supplied) (setq out (cons supplied out)))))))
    out))

(defun nl-ns-in--binding-vars (bindings)
  "Return the variables a `let'-style BINDINGS list binds."
  (let ((out nil))
    (dolist (binding bindings)
      (cond ((symbolp binding) (setq out (cons binding out)))
            ((and (consp binding) (symbolp (car binding)))
             (setq out (cons (car binding) out)))))
    out))

(defun nl-ns-in--reject-bindings (vars map)
  "Signal if VARS binds a declared member in MAP."
  (dolist (var vars)
    (when (gethash var map)
      (signal 'nl-ns-in-member-binding-error
              (list (format "nl-ns-in: `%s' is a namespace member; rename the local"
                            var)
                    var)))))

(defun nl-ns-in--rewrite-seq (forms map)
  "Rewrite each element of FORMS, preserving an improper tail."
  (cond ((null forms) nil)
        ((not (consp forms)) (nl-ns-in--rewrite forms map))
        (t (cons (nl-ns-in--rewrite (car forms) map)
                 (nl-ns-in--rewrite-seq (cdr forms) map)))))

(defun nl-ns-in--rewrite-arglist (arglist map)
  "Rewrite default forms in ARGLIST while preserving binding syntax."
  (let ((out nil))
    (dolist (arg (if (listp arglist) arglist nil))
      (setq out
            (cons (if (consp arg)
                      (cons (car arg)
                            (cons (nl-ns-in--rewrite (car (cdr arg)) map)
                                  (cdr (cdr arg))))
                    arg)
                  out)))
    (nreverse out)))

(defun nl-ns-in--rewrite-backquote (template map depth)
  "Rewrite evaluated unquotes in TEMPLATE at quasiquote DEPTH.
Literal template positions remain data.  Nested quasiquotes are retained as
data until their own evaluation, so only unquotes at depth one are rewritten."
  (cond
   ((not (consp template)) template)
   ((memq (car template) '(\` backquote))
    (list (car template) (nl-ns-in--rewrite-backquote
                           (car (cdr template)) map (1+ depth))))
   ((memq (car template) '(\, \,@ comma comma-at))
    (if (= depth 1)
        (list (car template) (nl-ns-in--rewrite (car (cdr template)) map))
      (list (car template) (nl-ns-in--rewrite-backquote
                            (car (cdr template)) map (1- depth)))))
   (t (cons (nl-ns-in--rewrite-backquote (car template) map depth)
            (nl-ns-in--rewrite-backquote (cdr template) map depth)))))

(defun nl-ns-in--rewrite (form map)
  "Rewrite FORM using MAP, rejecting definitions and bindings outside its rules."
  (cond
   ((symbolp form) (or (gethash form map) form))
   ((not (consp form)) form)
   ((eq (car form) 'quote) form)
   ((memq (car form) '(\` backquote))
    (list (car form) (nl-ns-in--rewrite-backquote (car (cdr form)) map 1)))
   ((eq (car form) 'function)
    (let ((target (car (cdr form))))
      (list 'function (if (symbolp target)
                          (or (gethash target map) target)
                        (nl-ns-in--rewrite target map)))))
   ((eq (car form) 'lambda)
    (let ((args (car (cdr form))))
      (nl-ns-in--reject-bindings (nl-ns-in--arglist-vars args) map)
      (cons 'lambda (cons (nl-ns-in--rewrite-arglist args map)
                          (nl-ns-in--rewrite-seq (cdr (cdr form)) map)))))
   ((memq (car form) '(let let*)) (nl-ns-in--rewrite-let form map))
   ((memq (car form) nl-ns-in-definition-heads)
    (nl-ns-in--rewrite-definition form map))
   ((memq (car form) '(dolist dotimes)) (nl-ns-in--rewrite-loop form map))
   ((eq (car form) 'condition-case) (nl-ns-in--rewrite-condition-case form map))
   (t (nl-ns-in--rewrite-seq form map))))

(defun nl-ns-in--rewrite-let (form map)
  "Rewrite a `let' or `let*' FORM after rejecting member bindings."
  (let ((bindings (car (cdr form))))
    (nl-ns-in--reject-bindings (nl-ns-in--binding-vars bindings) map)
    (cons (car form)
          (cons (nl-ns-in--rewrite-seq bindings map)
                (nl-ns-in--rewrite-seq (cdr (cdr form)) map)))))

(defun nl-ns-in--rewrite-loop (form map)
  "Rewrite dolist or dotimes FORM after rejecting its member binding."
  (let* ((spec (car (cdr form))) (var (and (consp spec) (car spec))))
    (when (symbolp var) (nl-ns-in--reject-bindings (list var) map))
    (cons (car form) (cons (nl-ns-in--rewrite-seq spec map)
                           (nl-ns-in--rewrite-seq (cdr (cdr form)) map)))))

(defun nl-ns-in--rewrite-condition-case (form map)
  "Rewrite condition-case FORM after rejecting its handler variable binding."
  (let ((var (car (cdr form))))
    (when (symbolp var) (nl-ns-in--reject-bindings (list var) map))
    (cons 'condition-case (nl-ns-in--rewrite-seq (cdr form) map))))

(defun nl-ns-in--rewrite-definition (form map)
  "Rewrite a definition FORM, requiring its name to be a declared member."
  (let ((head (car form)) (name (car (cdr form))))
    (unless (gethash name map)
      (signal 'nl-ns-in-non-member-error
              (list (format "nl-ns-in: `%s' is not a declared namespace member"
                            name)
                    name)))
    (if (memq head '(defvar defconst defcustom))
        (cons head (cons (gethash name map)
                         (nl-ns-in--rewrite-seq (cdr (cdr form)) map)))
      (let ((args (car (cdr (cdr form)))))
        (nl-ns-in--reject-bindings (nl-ns-in--arglist-vars args) map)
        (cons head (cons (gethash name map)
                         (cons (nl-ns-in--rewrite-arglist args map)
                               (nl-ns-in--rewrite-seq
                                (cdr (cdr (cdr form))) map))))))))

;;;; Entry points -------------------------------------------------------

(defun nl-ns-expand (name body)
  "Return BODY rewritten inside namespace NAME, without evaluating it.
This is a pure function of NAME's declaration and BODY."
  (let ((map (make-hash-table :test 'eq)))
    (dolist (sym (nl-ns-member-list name))
      (puthash sym (nl-ns-qualify name sym) map))
    (nl-ns-in--rewrite-seq body map)))

(defmacro nl-ns-in (name &rest body)
  "Evaluate BODY with NAME's declared members written unqualified.
Definitions must name declared members.  Binding a declared member is an
error; rename the local.  Quoted data and backquote templates stay literal,
but unquotes are evaluated and rewritten."
  (declare (indent 1))
  (nl-ns--entry name)
  (cons 'progn (nl-ns-expand name body)))

(provide 'nl-ns-in)

;;; nl-ns-in.el ends here
