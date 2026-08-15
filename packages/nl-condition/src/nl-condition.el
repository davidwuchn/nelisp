;;; nl-condition.el --- Restartable condition system for NeLisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 169 (nl-prelude / nl-condition) Phase 4: a Common-Lisp-style
;; condition system with restarts, as an opt-in library on plain Elisp
;; (runs on NeLisp standalone and host Emacs alike).
;;
;; Why: Elisp `condition-case' unwinds the stack BEFORE running the
;; handler, so by the time the handler sees the error, the dynamic
;; context of the error site is gone.  CL `handler-bind' runs handlers
;; BEFORE unwinding, which is what makes restarts possible: the
;; handler, still standing on the signaling frame, picks a recovery
;; strategy that some outer frame offered.
;;
;;   (nl-restart-case
;;       (nl-handler-bind ((file-missing
;;                          (lambda (c) (nl-invoke-restart 'use-default))))
;;         (load-config "/etc/app.conf"))
;;     (use-default () default-config)
;;     (retry (path) (load-config path)))
;;
;; Public API:
;;   `nl-signal'            signal without unwinding first
;;   `nl-handler-bind'      bind handlers that run pre-unwind
;;   `nl-restart-case'      offer named restarts around a form
;;   `nl-invoke-restart'    unwind to a restart and run its body
;;   `nl-find-restart'      is a restart currently established?
;;   `nl-compute-restarts'  names of established restarts, innermost first
;;
;; Semantics (CL model, scoped to this library):
;;   - Only `nl-signal' consults the handler stack; a plain `signal'
;;     from arbitrary Elisp does not (no global advice, non-invasive).
;;   - A handler that RETURNS declines: the next (outer) matching
;;     handler runs.  When every handler declines, `nl-signal' falls
;;     back to a plain `signal', so `condition-case' interop works.
;;   - While a handler runs, only handlers OUTER to it are visible,
;;     preventing self-recursion on re-signal.
;;   - `nl-invoke-restart' throws to the `nl-restart-case' frame; the
;;     restart body runs AFTER unwinding (so `unwind-protect' cleanups
;;     between the signal point and the restart frame have run), with
;;     the restart frame itself already popped.
;;
;; The condition object handed to handlers is (ERROR-SYMBOL . DATA),
;; the same shape `condition-case' binds.

;;; Code:

(require 'nl-prelude)

(define-error 'nl-control-error
  "Invoked a restart that is not established" 'nl-error)

;;;; Handler stack ----------------------------------------------------

(defvar nl--handler-stack nil
  "List of handler frames, innermost first.
Each frame is a list of (CONDITION . HANDLER-FN) pairs.")

(defvar nl--restart-stack nil
  "List of restart frames, innermost first.
Each frame is (CATCH-TAG (NAME . FN)...).")

(defun nl--condition-matches-p (condition error-symbol)
  "Return non-nil when CONDITION covers ERROR-SYMBOL.
Matching follows `condition-case': CONDITION must appear in
ERROR-SYMBOL's `error-conditions' (an undeclared ERROR-SYMBOL matches
itself and `error')."
  (let ((conditions (or (get error-symbol 'error-conditions)
                        (list error-symbol 'error))))
    (memq condition conditions)))

(defun nl-signal (error-symbol data)
  "Signal ERROR-SYMBOL with DATA without unwinding the stack first.
Run matching `nl-handler-bind' handlers innermost first, each with the
condition object (ERROR-SYMBOL . DATA) and with only outer handlers
visible.  A handler escapes by non-local exit (typically
`nl-invoke-restart'); a handler that returns declines.  When no
handler handles the condition, fall back to (signal ERROR-SYMBOL
DATA), which `condition-case' can catch as usual."
  (let ((condition-object (cons error-symbol data))
        (frames nl--handler-stack))
    (while frames
      (let ((frame (car frames))
            (outer (cdr frames)))
        (dolist (binding frame)
          (when (nl--condition-matches-p (car binding) error-symbol)
            ;; Run the handler pre-unwind, seeing only outer handlers.
            (let ((nl--handler-stack outer))
              (funcall (cdr binding) condition-object)))))
      (setq frames (cdr frames)))
    (signal error-symbol data)))

(defmacro nl-handler-bind (bindings &rest body)
  "Run BODY with BINDINGS as pre-unwind condition handlers.
BINDINGS is a list of (CONDITION HANDLER-FN) where CONDITION is an
error symbol (matched like `condition-case' conditions) and HANDLER-FN
a function of one argument, the condition object.  Handlers fire for
`nl-signal' only, before any unwinding; see `nl-signal' for the
decline/fallback protocol."
  (declare (indent 1))
  `(let ((nl--handler-stack
          (cons (list ,@(mapcar (lambda (b)
                                  (unless (and (consp b) (symbolp (car b))
                                               (consp (cdr b)) (null (cddr b)))
                                    (error "nl-handler-bind: bad binding %S" b))
                                  `(cons ',(car b) ,(nth 1 b)))
                                bindings))
                nl--handler-stack)))
     ,@body))

;;;; Restarts ---------------------------------------------------------

(defmacro nl-restart-case (form &rest restarts)
  "Evaluate FORM with RESTARTS established.
Each restart is (NAME ARGLIST BODY...).  When `nl-invoke-restart'
transfers here, the stack is unwound to this frame (running
`unwind-protect' cleanups on the way), the restart frame is popped,
and the restart's BODY runs with ARGLIST bound to the invocation
arguments; its value becomes the value of the whole form."
  (declare (indent 1))
  (let ((tag (gensym "nl--restart-tag-"))
        (payload (gensym "nl--restart-payload-")))
    (dolist (r restarts)
      (unless (and (consp r) (symbolp (car r)) (car r)
                   (consp (cdr r)) (listp (nth 1 r)))
        (error "nl-restart-case: bad restart clause %S" r)))
    `(let ((,payload
            (catch ',tag
              (let ((nl--restart-stack
                     (cons (list ',tag
                                 ,@(mapcar (lambda (r)
                                             `(cons ',(car r)
                                                    (lambda ,(nth 1 r)
                                                      ,@(cddr r))))
                                           restarts))
                           nl--restart-stack)))
                (cons 'nl--value ,form)))))
       (if (eq (car ,payload) 'nl--value)
           (cdr ,payload)
         (apply (cadr ,payload) (cddr ,payload))))))

(defun nl--find-restart-frame (name)
  "Return (TAG . FN) for the innermost established restart NAME."
  (let ((frames nl--restart-stack)
        (found nil))
    (while (and frames (not found))
      (let ((hit (assq name (cdr (car frames)))))
        (when hit
          (setq found (cons (car (car frames)) (cdr hit)))))
      (setq frames (cdr frames)))
    found))

(defun nl-find-restart (name)
  "Return non-nil when restart NAME is currently established."
  (and (nl--find-restart-frame name) name))

(defun nl-compute-restarts ()
  "Return the names of all established restarts, innermost first."
  (let ((names nil))
    (dolist (frame nl--restart-stack)
      (dolist (r (cdr frame))
        (push (car r) names)))
    (nreverse names)))

(defun nl-invoke-restart (name &rest args)
  "Transfer control to the innermost established restart NAME.
Unwind to its `nl-restart-case' (running `unwind-protect' cleanups),
then run the restart body with ARGS.  Signal `nl-control-error' when
NAME is not established."
  (let ((found (nl--find-restart-frame name)))
    (unless found
      (signal 'nl-control-error (list name)))
    (throw (car found) (cons 'nl--restart (cons (cdr found) args)))))

(provide 'nl-condition)

;;; nl-condition.el ends here