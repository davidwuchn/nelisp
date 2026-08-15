;;; nl-contract.el --- Racket-style boundary contracts for NeLisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 Stage 4: dynamic contracts at module boundaries with blame
;; reporting (Doc 168 section 3.4).  Instead of static types, values
;; crossing a boundary are checked at run time, and a violation names
;; the party at fault: the CALLER broke an argument contract, or the
;; IMPLEMENTATION broke the return contract.
;;
;; Public API:
;;
;;   Combinators:  `nl->' (function contract, fixed arity)
;;                 `nl-result-of' (contract over nl-prelude Results)
;;                 flat contracts are any predicate: a function value
;;                 or a symbol naming one (`integerp', `stringp', ...)
;;   Checking:     `nl-contract-check' `nl-contract-describe'
;;   Boundary:     `nl-provide/contract' `nl-contract-remove'
;;                 `nl-contract-wrapped-p'
;;   Error:        `nl-contract-error' (under `nl-error')
;;   Disable flag: `nl-contract--enabled' (wrap-time, default t)
;;
;; Blame semantics (Doc 170 section 7): a wrapped function checks each
;; argument against its domain contract -- a failure blames the CALLER
;; and names the 0-based argument index -- then calls the original and
;; checks the return value against the range contract -- a failure
;; blames the IMPLEMENTATION at position `return'.  The signaled
;; `nl-contract-error' data and the violation-log record both carry:
;; the contracted function, the blamed party, the position, the
;; violated contract (in `nl-contract-describe' notation), and the
;; offending value.  Violations are also logged through nl-safe's
;; `nl-safe--log-violation' with `:kind' `contract', so they accrue in
;; the same Doc 168 Phase 6 gate data set as borrow/bounds/resource
;; violations (subject to the same `nl-safe-log-violations' switch).
;;
;; Wrapping mechanics: `nl-provide/contract' replaces the function
;; cell (`fset') of an EXISTING named function with a checking wrapper
;; that keeps the original in a hash table.  Re-providing is
;; idempotent -- it re-wraps the stored ORIGINAL, never the wrapper --
;; and `nl-contract-remove' restores the original.  The contract lives
;; at the boundary where `nl-provide/contract' ran: code that obtained
;; the raw function value before wrapping (or after removal) sees the
;; unchecked function.
;;
;; Disable flag: unlike nl-safe's expansion-time gate, wrapping is a
;; runtime act, so expansion identity is not applicable here.  The
;; equivalent guarantee is: when `nl-contract--enabled' is nil at wrap
;; time, `nl-provide/contract' is a no-op and the function cell is
;; left untouched -- zero overhead, nothing to strip.
;;
;; Design constraints:
;;   - pure Lisp, depends only on nl-prelude and nl-safe (Doc 168
;;     section 4.1; nothing here may depend on nl-check)
;;   - must run unchanged on `target/nelisp' standalone (no ert /
;;     cl-lib there; see test/nl-contract-standalone-smoke.el)

;;; Code:

(require 'nl-prelude)
(require 'nl-safe)

;;;; Errors -----------------------------------------------------------

(define-error 'nl-contract-error "Contract violation" 'nl-error)

;;;; Disable flag ------------------------------------------------------

(defvar nl-contract--enabled t
  "Non-nil makes `nl-provide/contract' install checking wrappers.
When nil at WRAP time, `nl-provide/contract' is a no-op: the function
cell is left untouched and no overhead remains.  Mirrors
`nl-safe--enabled', but gates the runtime wrapping act rather than
macro expansion (there is no expansion-identity question here).
Already-installed wrappers are not affected by later flips; use
`nl-contract-remove' to take a wrapper off.")

;;;; Contract values ---------------------------------------------------

;; Representation (plain vectors, like nl-safe's cells/pointers):
;;   function contract:  [nl--contract-> DOMS RANGE]
;;   Result contract:    [nl--contract-result OK-CONTRACT ERR-CONTRACT]
;; A flat contract is anything else that is a predicate: a function
;; value or a symbol naming a function.

(defun nl-> (&rest contracts)
  "Build a function contract from CONTRACTS; the last one is the range.
All contracts before the last are the domain contracts, one per
argument (fixed arity).  Each may be a flat predicate (function value
or symbol), an `nl-result-of' contract, or another `nl->' contract
\(checked as `functionp' only -- no higher-order wrapping in v1)."
  (unless (consp contracts)
    (error "nl->: needs at least a range contract"))
  (let ((doms nil)
        (rest contracts))
    (while (cdr rest)
      (setq doms (cons (car rest) doms))
      (setq rest (cdr rest)))
    (vector 'nl--contract-> (nreverse doms) (car rest))))

(defun nl-result-of (ok-contract err-contract)
  "Build a contract over nl-prelude Results.
A value satisfies it when it is a Result whose payload satisfies
OK-CONTRACT (for an ok) or ERR-CONTRACT (for an err)."
  (vector 'nl--contract-result ok-contract err-contract))

(defun nl-contract--fn-p (object)
  "Return non-nil when OBJECT is an `nl->' function contract."
  (and (vectorp object)
       (= (length object) 3)
       (eq (aref object 0) 'nl--contract->)))

(defun nl-contract--result-p (object)
  "Return non-nil when OBJECT is an `nl-result-of' contract."
  (and (vectorp object)
       (= (length object) 3)
       (eq (aref object 0) 'nl--contract-result)))

(defun nl-contract-check (contract value)
  "Return non-nil when VALUE satisfies CONTRACT.
CONTRACT is a flat predicate (function value or symbol naming one),
an `nl-result-of' contract, or an `nl->' contract (satisfied by any
`functionp' value; v1 does not wrap higher-order values).  Signal an
error when CONTRACT is not a contract at all."
  (cond
   ((nl-contract--result-p contract)
    (and (nl-result-p value)
         (nl-contract-check (aref contract (if (nl-ok-p value) 1 2))
                            (cdr value))))
   ((nl-contract--fn-p contract)
    (and (functionp value) t))
   ((and (symbolp contract) contract)
    (and (funcall contract value) t))
   ((functionp contract)
    (and (funcall contract value) t))
   (t (error "nl-contract-check: not a contract: %S" contract))))

(defun nl-contract-describe (contract)
  "Return a printable description of CONTRACT for blame reports.
Symbols name themselves, combinator contracts print as their
constructor forms, and anonymous function values print as `function'."
  (cond
   ((nl-contract--result-p contract)
    (list 'nl-result-of
          (nl-contract-describe (aref contract 1))
          (nl-contract-describe (aref contract 2))))
   ((nl-contract--fn-p contract)
    (cons 'nl-> (append (mapcar #'nl-contract-describe (aref contract 1))
                        (list (nl-contract-describe (aref contract 2))))))
   ((and (symbolp contract) contract) contract)
   ((functionp contract) 'function)
   (t contract)))

;;;; Blame -------------------------------------------------------------

(defun nl-contract--blame (function party position contract value)
  "Log and signal an `nl-contract-error' blaming PARTY for FUNCTION.
PARTY is `caller' or `implementation'.  POSITION is the 0-based
argument index, the symbol `return', or the symbol `arity'.  CONTRACT
is the violated contract (described via `nl-contract-describe' in the
report); VALUE is the offending value.  The record is also pushed to
nl-safe's violation log with `:kind' `contract' (Doc 168 Phase 6 gate
data), subject to `nl-safe-log-violations'."
  (let ((desc (nl-contract-describe contract)))
    (nl-safe--log-violation
     (list :kind 'contract
           :function function
           :blame party
           :position position
           :contract desc
           :value value))
    (signal 'nl-contract-error
            (list :function function
                  :blame party
                  :position position
                  :contract desc
                  :value value))))

;;;; Wrapping ----------------------------------------------------------

(defvar nl-contract--originals (make-hash-table :test 'eq)
  "Map of contracted function name -> original (pre-wrap) definition.
`nl-provide/contract' consults this so re-providing re-wraps the
original rather than stacking wrappers; `nl-contract-remove' restores
from it.")

(defun nl-contract--check-args (name doms args)
  "Check ARGS of the contracted function NAME against DOMS.
An arity mismatch or a failing domain contract blames the caller."
  (let ((expected (length doms))
        (got (length args)))
    (unless (= got expected)
      (nl-contract--blame name 'caller 'arity (list 'arity expected) got)))
  (let ((i 0)
        (ds doms)
        (as args))
    (while ds
      (unless (nl-contract-check (car ds) (car as))
        (nl-contract--blame name 'caller i (car ds) (car as)))
      (setq i (1+ i))
      (setq ds (cdr ds))
      (setq as (cdr as)))))

(defun nl-contract--make-wrapper (name original contract)
  "Return the checking wrapper closure for NAME around ORIGINAL.
CONTRACT is an `nl->' function contract.  Arguments are checked
against the domain contracts (caller blame), the return value against
the range contract (implementation blame)."
  (let ((doms (aref contract 1))
        (range (aref contract 2)))
    (lambda (&rest args)
      (nl-contract--check-args name doms args)
      (let ((result (apply original args)))
        (unless (nl-contract-check range result)
          (nl-contract--blame name 'implementation 'return range result))
        result))))

(defun nl-contract--provide-1 (name contract)
  "Install CONTRACT on the existing function NAME; return NAME.
Backing function for `nl-provide/contract' (which builds CONTRACT
from its spec DSL).  No-op when `nl-contract--enabled' is nil.
Re-providing re-wraps the stored original, so the wrapper never
stacks."
  (if (not nl-contract--enabled)
      name
    (unless (and (symbolp name) name (fboundp name))
      (error "nl-provide/contract: %S is not an existing function" name))
    (unless (nl-contract--fn-p contract)
      (error "nl-provide/contract: %S needs an nl-> function contract, got %S"
             name contract))
    (let ((original (or (gethash name nl-contract--originals)
                        (symbol-function name))))
      (puthash name original nl-contract--originals)
      (fset name (nl-contract--make-wrapper name original contract))
      name)))

(defun nl-contract--spec-form (spec)
  "Translate the contract DSL SPEC into an evaluatable form.
Bare symbols are predicate names and get quoted (Racket-style
spelling); (nl-> ...) and (nl-result-of ...) recurse into their
arguments; anything else -- `lambda' forms, sharp-quoted functions,
arbitrary expressions -- evaluates as written."
  (cond
   ((and (symbolp spec) spec) (list 'quote spec))
   ((and (consp spec) (memq (car spec) '(nl-> nl-result-of)))
    (cons (car spec) (mapcar #'nl-contract--spec-form (cdr spec))))
   (t spec)))

(defmacro nl-provide/contract (&rest specs)
  "Attach boundary contracts to existing functions; SPECS are (NAME CONTRACT).
Each NAME (unquoted symbol) must be an already-defined function; its
function cell is replaced with a wrapper that checks every call:
arguments against the domain contracts (a violation blames the
caller) and the return value against the range contract (a violation
blames the implementation).  CONTRACT must be an `nl->' form; inside
it bare symbols are predicate names, so Doc 170's example reads

  (nl-provide/contract
    (parse-config (nl-> stringp (nl-result-of hash-table-p symbolp))))

Re-providing a NAME replaces its contract by re-wrapping the stored
original (idempotent, never stacks).  `nl-contract-remove' restores
the original.  When `nl-contract--enabled' is nil at wrap time this
is a no-op.  Returns the list of provided names."
  (let ((forms
         (mapcar
          (lambda (spec)
            (unless (and (consp spec)
                         (symbolp (car spec)) (car spec)
                         (consp (cdr spec)) (null (cddr spec)))
              (error "nl-provide/contract: spec must be (NAME CONTRACT), got %S"
                     spec))
            (list 'nl-contract--provide-1
                  (list 'quote (car spec))
                  (nl-contract--spec-form (car (cdr spec)))))
          specs)))
    (cons 'progn
          (append forms
                  (list (list 'quote (mapcar #'car specs)))))))

(defun nl-contract-remove (name)
  "Remove the contract wrapper from NAME, restoring the original.
Return NAME when a wrapper was removed, nil when NAME was not
contracted."
  (let ((original (gethash name nl-contract--originals)))
    (when original
      (fset name original)
      (remhash name nl-contract--originals)
      name)))

(defun nl-contract-wrapped-p (name)
  "Return non-nil when the function NAME currently has a contract wrapper."
  (and (gethash name nl-contract--originals) t))

(provide 'nl-contract)

;;; nl-contract.el ends here
