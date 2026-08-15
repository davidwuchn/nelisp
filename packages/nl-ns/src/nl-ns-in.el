;;; nl-ns-in.el --- A namespace you can actually write in -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The other half of Doc 169 defect #6.  `nl-ns.el' reports where the
;; namespace boundaries Elisp cannot enforce have been crossed; this
;; file lets you write inside one.
;;
;;   (nl-ns-define text)
;;
;;   (nl-ns-in text
;;     (defvar limit 80)
;;     (defun wrap (s) (chunk s limit))     ; calls text-chunk
;;     (defun chunk (s n) (substring s 0 n)))
;;
;;   ;; defines text-limit, text-wrap, text-chunk -- real global names.
;;
;; Public API:
;;
;;   `nl-ns-define' `nl-ns-members' `nl-ns-prefix' `nl-ns-member-list'
;;   `nl-ns-in' `nl-ns-qualify' `nl-ns-expand'
;;   `nl-ns-clear-namespaces'
;;
;; The resolution rule is the whole design, so it is stated once and
;; kept small:
;;
;;   A symbol is rewritten if and only if it is (a) defined by a
;;   top-level definition inside this block, or declared with
;;   `nl-ns-members', AND (b) not lexically bound at that point.
;;
;; Nothing else is touched.  `car', `mapcar', another package's
;; functions, keywords, and every symbol you did not define here come
;; out unchanged.  That is deliberately narrower than names.el, which
;; resolves a symbol by asking whether the qualified name happens to be
;; `fboundp' right now -- making expansion depend on load order and on
;; what else has been loaded.  This rule is purely syntactic and closed
;; over the block, so the same source always expands to the same code.
;;
;; What you do NOT get, said plainly:
;;
;; - No isolation.  `text-wrap' is an ordinary global symbol; another
;;   file can still define it and win.  This is an abbreviation for
;;   writing, not a separate obarray.  Use `nl-ns-check' (nl-ns.el) to
;;   detect that case -- the two halves of this package are meant to be
;;   used together.
;; - No privacy.  A `--' name inside a block is still reachable from
;;   anywhere; `ns-private-escape' is how you find out that it was.
;; - The debugger, backtraces and `M-.' show the qualified name,
;;   because that is the function's real name.  Same as Rust, Clojure
;;   and Common Lisp; unlike them, your source says the short one.
;; - Quoted symbols are NOT rewritten (see `nl-ns-in'), so pass
;;   function references as #'name inside a block.

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
  "Declare NAME as a namespace.
PROPERTIES accepts `:prefix STRING', defaulting to \"NAME-\".  Members
accumulate through `nl-ns-in' and `nl-ns-members'; re-defining a
namespace resets them, so a file can be reloaded during development."
  (unless (and name (symbolp name))
    (error "nl-ns-define: NAME must be a non-nil symbol, got %S" name))
  (let ((prefix (plist-get properties :prefix))
        (unknown nil)
        (tail properties))
    (while tail
      (unless (eq (car tail) :prefix)
        (setq unknown (cons (car tail) unknown)))
      (setq tail (cdr (cdr tail))))
    (when unknown
      (error "nl-ns-define: unknown properties %S" (nreverse unknown)))
    (when (and prefix (not (stringp prefix)))
      (error "nl-ns-define: :prefix must be a string, got %S" prefix))
    `(eval-and-compile
       (puthash ',name
                (list :prefix ,(or prefix (concat (symbol-name name) "-"))
                      :members nil)
                nl-ns--namespaces)
       ',name)))

(defun nl-ns-prefix (name)
  "Return the prefix string of namespace NAME."
  (plist-get (nl-ns--entry name) :prefix))

(defun nl-ns-member-list (name)
  "Return the declared member symbols of namespace NAME, in order."
  (reverse (plist-get (nl-ns--entry name) :members)))

(defun nl-ns--add-members (name symbols)
  "Add SYMBOLS to namespace NAME's member set."
  (let* ((entry (nl-ns--entry name))
         (members (plist-get entry :members)))
    (dolist (sym symbols)
      (unless (memq sym members)
        (setq members (cons sym members))))
    (puthash name (plist-put entry :members members) nl-ns--namespaces)
    name))

(defmacro nl-ns-members (name &rest symbols)
  "Declare SYMBOLS as members of namespace NAME.
Use this to make names defined in one `nl-ns-in' block resolvable from
another block of the same namespace, or to name something defined
outside any block."
  `(eval-and-compile (nl-ns--add-members ',name ',symbols)))

(defun nl-ns-qualify (name symbol)
  "Return SYMBOL prefixed with namespace NAME's prefix."
  (intern (concat (nl-ns-prefix name) (symbol-name symbol))))

;;;; Definition scanning -------------------------------------------------

(defconst nl-ns-in-definition-heads
  '(defun defmacro defsubst defvar defconst defcustom cl-defun cl-defmacro)
  "Heads whose second element `nl-ns-in' treats as a definition to rename.
`defalias' and `define-error' are absent on purpose: their name is a
quoted datum, and quoted data is never rewritten.")

(defun nl-ns-in--defined-symbol (form)
  "Return the symbol FORM defines, or nil."
  (and (consp form)
       (memq (car form) nl-ns-in-definition-heads)
       (symbolp (car (cdr form)))
       (car (cdr form))))

(defun nl-ns-in--scan (body)
  "Return the symbols defined by the top-level forms of BODY."
  (let ((out nil))
    (dolist (form body)
      (let ((sym (nl-ns-in--defined-symbol form)))
        (when sym (setq out (cons sym out)))))
    (nreverse out)))

;;;; Rewriting -----------------------------------------------------------

(defconst nl-ns-in--binder-heads '(let let*)
  "Heads whose second element is a `let'-shaped binding list.")

(defun nl-ns-in--arglist-vars (arglist)
  "Return the variables ARGLIST binds, skipping lambda-list markers."
  (let ((out nil))
    (dolist (arg (if (listp arglist) arglist nil))
      (cond
       ((and arg (symbolp arg)
             (not (eq (aref (symbol-name arg) 0) ?&)))
        (setq out (cons arg out)))
       ;; Optional, keyword and aux arguments can carry an init form
       ;; and a supplied-p variable.  The latter is bound too.
       ((consp arg)
        (let ((var (car arg))
              (supplied (car (cdr (cdr arg)))))
          ;; A keyword argument may spell its variable as
          ;; ((:keyword var) INIT SUPPLIED-P).
          (when (and (consp var) (symbolp (car (cdr var))))
            (setq var (car (cdr var))))
          (when (symbolp var)
            (setq out (cons var out)))
          (when (symbolp supplied)
            (setq out (cons supplied out)))))))
    out))

(defun nl-ns-in--binding-vars (bindings)
  "Return the variables a `let'-style BINDINGS list binds."
  (let ((out nil))
    (dolist (binding bindings)
      (cond
       ((symbolp binding) (when binding (setq out (cons binding out))))
       ((consp binding)
        (when (symbolp (car binding))
          (setq out (cons (car binding) out))))))
    out))

(defun nl-ns-in--arg-spec-vars (arg)
  "Return the variables bound by one lambda-list ARG specification."
  (cond
   ((symbolp arg)
    (if (eq (aref (symbol-name arg) 0) ?&) nil (list arg)))
   ((consp arg)
    (let ((var (car arg))
          (supplied (car (cdr (cdr arg))))
          (out nil))
      (when (and (consp var) (symbolp (car (cdr var))))
        (setq var (car (cdr var))))
      (when (symbolp var) (setq out (cons var out)))
      (when (symbolp supplied) (setq out (cons supplied out)))
      out))
   (t nil)))

(defun nl-ns-in--rewrite-arglist (arglist map bound)
  "Rewrite default forms in ARGLIST while preserving its binding syntax."
  (let ((out nil)
        (seen bound))
    (dolist (arg (if (listp arglist) arglist nil))
      (if (consp arg)
          (setq out
                (cons (cons (car arg)
                            (cons (nl-ns-in--rewrite (car (cdr arg)) map seen)
                                  (cdr (cdr arg))))
                      out))
        (setq out (cons arg out)))
      (setq seen (append (nl-ns-in--arg-spec-vars arg) seen)))
    (nreverse out)))

(defun nl-ns-in--resolve (symbol map bound)
  "Return SYMBOL's replacement from MAP unless it is in BOUND."
  (if (memq symbol bound)
      symbol
    (or (gethash symbol map) symbol)))

(defun nl-ns-in--rewrite-seq (forms map bound)
  "Rewrite each element of FORMS, preserving an improper tail."
  (cond
   ((null forms) nil)
   ((not (consp forms)) (nl-ns-in--rewrite forms map bound))
   (t (cons (nl-ns-in--rewrite (car forms) map bound)
            (nl-ns-in--rewrite-seq (cdr forms) map bound)))))

(defun nl-ns-in--rewrite (form map bound)
  "Rewrite FORM, replacing MAP's keys unless shadowed by BOUND."
  (cond
   ((symbolp form) (nl-ns-in--resolve form map bound))
   ((not (consp form)) form)
   ;; Quoted data is left alone: a quoted symbol is as likely to be a
   ;; keyword, a tag or a plain datum as a function reference.  Use #'
   ;; when you mean the function.
   ((eq (car form) 'quote) form)
   ((eq (car form) 'function)
    (let ((target (car (cdr form))))
      (if (and (consp target) (eq (car target) 'lambda))
          (list 'function (nl-ns-in--rewrite target map bound))
        (list 'function (nl-ns-in--rewrite-symbol-only target map bound)))))
   ((eq (car form) 'lambda)
    (let ((args (car (cdr form))))
      (cons 'lambda
            (cons (nl-ns-in--rewrite-arglist args map bound)
                  (nl-ns-in--rewrite-seq
                   (cdr (cdr form)) map
                   (append (nl-ns-in--arglist-vars args) bound))))))
   ((memq (car form) nl-ns-in--binder-heads)
    (nl-ns-in--rewrite-let form map bound))
   ((memq (car form) nl-ns-in-definition-heads)
    (nl-ns-in--rewrite-definition form map bound))
   ((memq (car form) '(dolist dotimes))
    (nl-ns-in--rewrite-loop form map bound))
   ((eq (car form) 'condition-case)
    (nl-ns-in--rewrite-condition-case form map bound))
   (t (nl-ns-in--rewrite-seq form map bound))))

(defun nl-ns-in--rewrite-symbol-only (form map bound)
  "Rewrite FORM when it is a symbol; otherwise rewrite it normally."
  (if (symbolp form)
      (nl-ns-in--resolve form map bound)
    (nl-ns-in--rewrite form map bound)))

(defun nl-ns-in--rewrite-condition-case (form map bound)
  "Rewrite condition-case FORM, binding its variable only in handlers."
  (let* ((var (car (cdr form)))
         (protected (car (cdr (cdr form))))
         (handlers (cdr (cdr (cdr form))))
         (handler-bound (if (symbolp var) (cons var bound) bound))
         (out nil))
    (dolist (handler handlers)
      ;; The condition names are declarations, not evaluated references;
      ;; only a handler body sees VAR's lexical binding.
      (if (consp handler)
          (setq out
                (cons (cons (car handler)
                            (nl-ns-in--rewrite-seq (cdr handler) map
                                                   handler-bound))
                      out))
        (setq out (cons (nl-ns-in--rewrite handler map bound) out))))
    (cons 'condition-case
          (cons var
                (cons (nl-ns-in--rewrite protected map bound)
                      (nreverse out))))))

(defun nl-ns-in--rewrite-loop (form map bound)
  "Rewrite dolist or dotimes FORM, respecting its loop variable's scope."
  (let* ((head (car form))
         (spec (car (cdr form)))
         (var (and (consp spec) (car spec)))
         (inner (if (symbolp var) (cons var bound) bound)))
    (cons head
          (cons (if (consp spec)
                    ;; The iteration form is outside the binding, while
                    ;; the optional result form is inside it.
                    (cons var
                          (cons (nl-ns-in--rewrite (car (cdr spec)) map bound)
                                (nl-ns-in--rewrite-seq (cdr (cdr spec)) map
                                                       inner)))
                  (nl-ns-in--rewrite spec map bound))
                (nl-ns-in--rewrite-seq (cdr (cdr form)) map inner)))))

(defun nl-ns-in--rewrite-let (form map bound)
  "Rewrite a `let' / `let*' FORM, honouring the shadowing it introduces."
  (let* ((head (car form))
         (bindings (car (cdr form)))
         (body (cdr (cdr form)))
         (vars (nl-ns-in--binding-vars bindings))
         (inner (append vars bound))
         (seen bound)
         (out nil))
    (dolist (binding bindings)
      (cond
       ((symbolp binding) (setq out (cons binding out)))
       ((consp binding)
        ;; `let' evaluates every init in the outer scope; `let*' sees
        ;; the bindings made so far.
        (setq out (cons (cons (car binding)
                              (nl-ns-in--rewrite-seq
                               (cdr binding) map
                               (if (eq head 'let*) seen bound)))
                        out))
        (when (eq head 'let*)
          (setq seen (cons (car binding) seen))))
       (t (setq out (cons binding out)))))
    (cons head
          (cons (nreverse out)
                (nl-ns-in--rewrite-seq body map inner)))))

(defun nl-ns-in--rewrite-definition (form map bound)
  "Rewrite a definition FORM: rename it, then rewrite its body."
  (let* ((head (car form))
         (name (car (cdr form)))
         (renamed (nl-ns-in--resolve name map bound)))
    (if (memq head '(defvar defconst defcustom))
        (cons head (cons renamed (nl-ns-in--rewrite-seq
                                  (cdr (cdr form)) map bound)))
      (let* ((args (car (cdr (cdr form))))
             (inner (append (nl-ns-in--arglist-vars args) bound)))
        (cons head
              (cons renamed
                    (cons (nl-ns-in--rewrite-arglist args map bound)
                          (nl-ns-in--rewrite-seq
                           (cdr (cdr (cdr form))) map inner))))))))

;;;; Entry points ---------------------------------------------------------

(defun nl-ns-expand (name body)
  "Return BODY rewritten inside namespace NAME, without evaluating it.
The counterpart of `nl-ns-in' for tests and for reading the expansion."
  (let* ((defined (nl-ns-in--scan body))
         (members (append defined (nl-ns-member-list name)))
         (map (make-hash-table :test 'eq)))
    (dolist (sym members)
      (puthash sym (nl-ns-qualify name sym) map))
    (nl-ns-in--rewrite-seq body map nil)))

(defmacro nl-ns-in (name &rest body)
  "Evaluate BODY with NAME's members written unqualified.
A symbol is rewritten if and only if it is defined by a top-level
definition in BODY or declared with `nl-ns-members', and is not
lexically bound at that point.  Everything else is untouched.

The names this block defines are added to NAME's member set, so a
later block of the same namespace can use them unqualified too."
  (declare (indent 1))
  (nl-ns--entry name)
  (nl-ns--add-members name (nl-ns-in--scan body))
  (cons 'progn (nl-ns-expand name body)))

(provide 'nl-ns-in)

;;; nl-ns-in.el ends here
