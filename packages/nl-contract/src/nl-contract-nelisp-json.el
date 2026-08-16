;;; nl-contract-nelisp-json.el --- contracts for the nelisp-json boundary -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The first real adoption of `nl-contract' (Doc 170 sections 7, 7.2).
;;
;; Everything in the nl-* family shipped unused, which left two claims
;; unproven: that the contract layer works on code it did not grow up
;; with, and that the Doc 168 Phase 6 gate can ever see violations from
;; something other than its own tests.  This file contracts a real
;; module boundary -- the `nelisp-json' public API -- and is the first
;; place either claim gets tested.
;;
;; DEPENDENCY DIRECTION.  `nelisp-json' is untouched and keeps its
;; dependency-free contract; this file depends on it, never the other
;; way round (Doc 168 section 4.1).  Nothing loads this file
;; automatically: a dev session, a test, or the violation-corpus target
;; requires it and calls `nl-contract-nelisp-json-arm'.  Production
;; callers that never load it see the raw functions.
;;
;;   (require 'nl-contract-nelisp-json)
;;   (nl-contract-nelisp-json-arm)      ; wrap
;;   ...
;;   (nl-contract-nelisp-json-disarm)   ; restore
;;
;; SCOPE.  Only the fixed-arity entry points are contracted.  `nl->' is
;; fixed-arity in v1 (Doc 170 section 7 deviations), so
;; `nelisp-json-parse-string', `nelisp-json-serialize' and
;; `nelisp-json-read-from-string' -- all `&rest' -- are deliberately
;; left alone rather than silently breaking their keyword arguments.
;; Widening `nl->' to optional/rest domains is the follow-up that would
;; let the parser side join.

;;; Code:

(require 'nl-contract)
(require 'nelisp-json)

(defun nl-contract-nelisp-json-value-p (value)
  "Return non-nil when VALUE is encodable by `nelisp-json-encode'.
Mirrors the documented input set of that function: nil, t, the false
sentinels, numbers, strings, vectors, hash tables, and lists (alist /
plist / array).  A symbol other than nil / t / a false sentinel is the
common caller mistake this catches at the boundary, where the blame
message names the caller instead of surfacing as an encoder error from
inside the module."
  (or (null value)
      (eq value t)
      (memq value '(:false :json-false))
      (numberp value)
      (stringp value)
      (vectorp value)
      (hash-table-p value)
      (listp value)))

(defconst nl-contract-nelisp-json-contracts
  '((nelisp-json-encode (nl-> nl-contract-nelisp-json-value-p stringp))
    (nelisp-json-encode-string (nl-> stringp stringp))
    (nelisp-json-pretty-print-string (nl-> stringp stringp)))
  "The contracted entry points and their contracts.
Each entry is the `nl-provide/contract' spec for one function.")

(defun nl-contract-nelisp-json-arm ()
  "Install the contracts on the `nelisp-json' public API.
Idempotent: re-arming rewraps the original functions rather than
stacking wrappers.  Returns the list of contracted names."
  (nl-provide/contract
   (nelisp-json-encode (nl-> nl-contract-nelisp-json-value-p stringp))
   (nelisp-json-encode-string (nl-> stringp stringp))
   (nelisp-json-pretty-print-string (nl-> stringp stringp)))
  (mapcar #'car nl-contract-nelisp-json-contracts))

(defun nl-contract-nelisp-json-disarm ()
  "Restore the uncontracted `nelisp-json' functions."
  (dolist (entry nl-contract-nelisp-json-contracts)
    (nl-contract-remove (car entry)))
  (mapcar #'car nl-contract-nelisp-json-contracts))

(provide 'nl-contract-nelisp-json)

;;; nl-contract-nelisp-json.el ends here
