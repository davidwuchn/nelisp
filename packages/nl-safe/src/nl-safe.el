;;; nl-safe.el --- Dynamic borrow cells and fat pointers for NeLisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 Stage 1: dynamic aliasing-XOR-mutation checking (`nl-cell'),
;; checked fat pointers over raw memory, and the `nl-unsafe' boundary.
;;
;; Public API:
;;
;;   Cells:        `nl-cell' `nl-cell-p' `nl-defcell'
;;                 `nl-with-borrow' (shared, n >= 0 concurrent)
;;                 `nl-with-borrow-mut' (exclusive)
;;   Fat pointer:  `nl-ptr-make' (unsafe primitive) `nl-ptr-p' `nl-ptr-len'
;;                 `nl-ptr-ref-u8' `nl-ptr-set-u8' `nl-ptr-ref-u64'
;;                 `nl-ptr-slice'
;;   Unsafe:       `nl-unsafe' `nl-safe-unsafe-primitives'
;;   Backend:      `nl-safe-ptr-backend' (integration point, see below)
;;                 `nl-safe-mock-alloc' `nl-safe-mock-free' `nl-safe-mock-ptr'
;;   Diagnostics:  `nl-safe-log-violations' `nl-safe--violation-log'
;;   Disable flag: `nl-safe--enabled' (expansion-time, default t)
;;
;; Representation (Doc 170 sections 3.2 and 4.1):
;;
;;   Cell:        [nl--cell VALUE STATE]
;;                STATE 0 = free, n > 0 = n shared borrows, -1 = exclusive
;;   Fat pointer: [nl--ptr BASE LEN GENERATION]
;;
;; Raw-memory backend indirection: host Emacs has no raw memory, and
;; wiring to the standalone's raw-memory primitives (`alloc-bytes',
;; `ptr-read-u8', ...) is follow-up work.  Every actual memory access
;; goes through the funcall'able `nl-safe-ptr-backend'; the default
;; backend is a pure-Lisp mock (vector-backed) so the whole checking
;; layer is testable on host Emacs AND on the standalone binary.
;; Swapping in a raw-memory backend is the single integration point.
;;
;; Disable flag (Doc 170 section 9): when `nl-safe--enabled' is nil at
;; macro-expansion time, `nl-with-borrow' / `nl-with-borrow-mut' and
;; the pointer accessors expand to the plain unchecked forms, with no
;; residue of the checking layer.  Like `nl-strict', the flag only
;; takes effect for expansions performed after it is set: flip it at
;; top level (or around an explicit `eval' / `macroexpand'), not
;; inside an already-compiled function body.
;;
;; Design constraints:
;;   - pure Lisp, depends only on nl-prelude (Doc 168 section 4.1)
;;   - must run unchanged on `target/nelisp' standalone (no ert there;
;;     see test/nl-safe-standalone-smoke.el)

;;; Code:

(require 'nl-prelude)

;;;; Errors -----------------------------------------------------------

(define-error 'nl-borrow-error "Borrow rule violation" 'nl-error)
(define-error 'nl-ptr-error "Fat pointer violation" 'nl-error)
(define-error 'nl-ptr-bounds-error "Fat pointer access out of bounds"
              'nl-ptr-error)
(define-error 'nl-ptr-generation-error
              "Fat pointer generation mismatch (use-after-free)"
              'nl-ptr-error)

;;;; Disable flag (Doc 170 section 9) ---------------------------------

(defvar nl-safe--enabled t
  "Non-nil expands nl-safe macros to their checked forms.
When nil at macro-expansion time, `nl-with-borrow',
`nl-with-borrow-mut', and the `nl-ptr-*' accessors expand to the
plain unchecked forms (expansion-identity gate, Doc 170 section 9).
Only expansions performed after the flip are affected; set it at top
level or around an explicit `eval' / `macroexpand'.")

;;;; Violation log (Doc 168 Phase 6 gate data source) ------------------

(defvar nl-safe-log-violations nil
  "Non-nil records each nl-safe violation in `nl-safe--violation-log'.
The violation is still signaled; logging is additional.")

(defvar nl-safe--violation-log nil
  "List of violation records, newest first.
Each record is a plist whose `:kind' is `borrow', `bounds', or
`generation'; the remaining keys are kind-specific (see
`nl-safe--log-violation' callers).  This log is the data source for
the Doc 168 Phase 6 go/no-go gate (share of dynamically caught
violations that a static checker could have caught), so records keep
as much context as the call site has.")

(defun nl-safe--log-violation (record)
  "Push RECORD onto `nl-safe--violation-log' when logging is enabled."
  (when nl-safe-log-violations
    (setq nl-safe--violation-log (cons record nl-safe--violation-log)))
  record)

;;;; Borrow cells (Doc 170 section 3) ----------------------------------

(defun nl-cell (value)
  "Wrap VALUE in a fresh borrow cell, initially unborrowed."
  (vector 'nl--cell value 0))

(defun nl-cell-p (object)
  "Return non-nil when OBJECT is a borrow cell."
  (and (vectorp object)
       (= (length object) 3)
       (eq (aref object 0) 'nl--cell)))

(defmacro nl-defcell (name init)
  "Define NAME as a variable holding a borrow cell around INIT.
Access the value through `nl-with-borrow' / `nl-with-borrow-mut'."
  (unless (and (symbolp name) name)
    (error "nl-defcell: NAME must be a symbol, got %S" name))
  `(defvar ,name (nl-cell ,init)
     ,(format "Borrow cell `%s' (nl-defcell)." name)))

(defun nl-safe--cell-value (cell)
  "Return the value inside CELL without any borrow bookkeeping.
Used by the unchecked expansions when `nl-safe--enabled' is nil."
  (aref cell 1))

(defun nl-safe--borrow-state-kind (state)
  "Classify the cell STATE integer as `free', `shared', or `exclusive'."
  (cond ((= state 0) 'free)
        ((< state 0) 'exclusive)
        (t 'shared)))

(defun nl-safe--borrow-violation (name state requested)
  "Log and signal an `nl-borrow-error' for the cell named NAME.
STATE is the cell state at the moment of the violation; REQUESTED is
the borrow kind being requested (`shared' or `exclusive')."
  (let ((existing (nl-safe--borrow-state-kind state)))
    (nl-safe--log-violation
     (list :kind 'borrow
           :cell name
           :existing existing
           :existing-shared-count (if (> state 0) state 0)
           :requested requested))
    (signal 'nl-borrow-error
            (list :cell name :existing existing :requested requested))))

(defun nl-safe--cell-check (cell caller)
  "Signal `nl-type-error' unless CELL is a borrow cell; CALLER names it."
  (unless (nl-cell-p cell)
    (signal 'nl-type-error (list caller cell))))

(defun nl-safe--borrow-shared (cell name)
  "Acquire a shared borrow on CELL (named NAME); return its value.
Signal `nl-borrow-error' when CELL is exclusively borrowed.  The state
is only incremented on success, so a failed acquire leaks nothing."
  (nl-safe--cell-check cell 'nl-with-borrow)
  (let ((state (aref cell 2)))
    (when (< state 0)
      (nl-safe--borrow-violation name state 'shared))
    (aset cell 2 (1+ state)))
  (aref cell 1))

(defun nl-safe--release-shared (cell)
  "Release one shared borrow on CELL."
  (aset cell 2 (1- (aref cell 2))))

(defun nl-safe--borrow-mut (cell name)
  "Acquire the exclusive borrow on CELL (named NAME); return its value.
Signal `nl-borrow-error' unless CELL is completely unborrowed."
  (nl-safe--cell-check cell 'nl-with-borrow-mut)
  (let ((state (aref cell 2)))
    (unless (= state 0)
      (nl-safe--borrow-violation name state 'exclusive))
    (aset cell 2 -1))
  (aref cell 1))

(defun nl-safe--release-mut (cell)
  "Release the exclusive borrow on CELL."
  (aset cell 2 0))

(defun nl-cell-set (cell value)
  "Store VALUE into CELL and return VALUE; the write-back API.
`nl-with-borrow-mut' binds its VAR to a one-time snapshot of the cell
value, so `setq' on VAR does NOT write back to the cell — call this
inside the exclusive-borrow body instead.  Signals `nl-borrow-error'
\(and logs the violation) unless the exclusive borrow is currently
held.  When `nl-safe--enabled' is nil the borrow-state check is
skipped and the write always happens."
  (nl-safe--cell-check cell 'nl-cell-set)
  (when (and nl-safe--enabled (/= (aref cell 2) -1))
    (nl-safe--borrow-violation 'nl-cell-set (aref cell 2) 'write))
  (aset cell 1 value)
  value)

(defun nl-safe--borrow-spec (spec caller)
  "Validate the borrow binding SPEC (VAR CELL) for the macro CALLER."
  (unless (and (consp spec) (symbolp (car spec)) (car spec)
               (consp (cdr spec)) (null (cddr spec)))
    (error "%s: binding must be (VAR CELL), got %S" caller spec))
  spec)

(defmacro nl-with-borrow (spec &rest body)
  "Run BODY with a shared borrow on a cell; SPEC is (VAR CELL).
VAR is bound to the cell value.  Any number of shared borrows may
coexist; an existing exclusive borrow signals `nl-borrow-error'.  The
borrow is released on any exit, including non-local ones
\(`unwind-protect').  When `nl-safe--enabled' is nil at expansion
time this expands to a plain unchecked `let'."
  (declare (indent 1))
  (nl-safe--borrow-spec spec 'nl-with-borrow)
  (let ((var (car spec))
        (cell (car (cdr spec))))
    (if (not nl-safe--enabled)
        `(let ((,var (nl-safe--cell-value ,cell))) ,@body)
      (let ((c (gensym "nl--cell")))
        `(let* ((,c ,cell)
                (,var (nl-safe--borrow-shared ,c ',cell)))
           (unwind-protect (progn ,@body)
             (nl-safe--release-shared ,c)))))))

(defmacro nl-with-borrow-mut (spec &rest body)
  "Run BODY with the exclusive borrow on a cell; SPEC is (VAR CELL).
VAR is bound to the cell value.  Any existing borrow (shared or
exclusive) signals `nl-borrow-error'.  The borrow is released on any
exit, including non-local ones (`unwind-protect').  When
`nl-safe--enabled' is nil at expansion time this expands to a plain
unchecked `let'."
  (declare (indent 1))
  (nl-safe--borrow-spec spec 'nl-with-borrow-mut)
  (let ((var (car spec))
        (cell (car (cdr spec))))
    (if (not nl-safe--enabled)
        `(let ((,var (nl-safe--cell-value ,cell))) ,@body)
      (let ((c (gensym "nl--cell")))
        `(let* ((,c ,cell)
                (,var (nl-safe--borrow-mut ,c ',cell)))
           (unwind-protect (progn ,@body)
             (nl-safe--release-mut ,c)))))))

;;;; Fat pointer backend (raw-memory integration point) ----------------

(defvar nl-safe-ptr-backend #'nl-safe--mock-backend
  "Funcall'able memory backend for fat pointer accessors.
Called as (funcall BACKEND OP BASE &optional A B) with OP one of:

  `ref-u8'      BASE OFFSET          -> byte
  `set-u8'      BASE OFFSET VALUE    -> ignored
  `ref-u64'     BASE OFFSET          -> unsigned little-endian integer
  `sub-base'    BASE DELTA           -> derived base for `nl-ptr-slice'
  `generation'  BASE                 -> current allocation generation,
                                        or nil to skip the check

This is THE raw-memory integration point (Doc 170 section 4): on the
standalone binary a follow-up backend maps these ops onto
`ptr-read-u8' / `ptr-write-u8' / `ptr-read-u64' / pointer arithmetic
and the allocator's generation counter.  The default is a pure-Lisp
mock (`nl-safe--mock-backend') so the checking layer runs on host
Emacs, which has no raw memory.")

;; Mock backend representation:
;;   store: [nl--mock-store GENERATION BYTES-VECTOR]
;;   base:  (STORE . START-OFFSET) -- slices share STORE, so freeing
;;          the store invalidates every derived pointer at once.

(defun nl-safe--mock-backend (op base &optional a b)
  "Pure-Lisp mock memory backend (see `nl-safe-ptr-backend').
OP, BASE, A, B follow the backend calling convention."
  (let ((store (car base))
        (start (cdr base)))
    (cond
     ((eq op 'ref-u8) (aref (aref store 2) (+ start a)))
     ((eq op 'set-u8) (aset (aref store 2) (+ start a) b))
     ((eq op 'ref-u64)
      (let ((bytes (aref store 2))
            (v 0)
            (i 8))
        (while (> i 0)
          (setq i (1- i))
          (setq v (+ (* v 256) (aref bytes (+ start a i)))))
        v))
     ((eq op 'sub-base) (cons store (+ start a)))
     ((eq op 'generation) (aref store 1))
     (t (error "nl-safe--mock-backend: unknown op %S" op)))))

(defun nl-safe-mock-alloc (len)
  "Allocate a LEN-byte mock memory base (generation 0, zero-filled)."
  (cons (vector 'nl--mock-store 0 (make-vector len 0)) 0))

(defun nl-safe-mock-free (object)
  "Simulate freeing the mock allocation behind OBJECT.
OBJECT is a mock base or a fat pointer over one.  Bumps the store
generation, so every fat pointer still holding the old generation
signals `nl-ptr-generation-error' on its next checked access."
  (let ((base (if (nl-ptr-p object) (aref object 1) object)))
    (aset (car base) 1 (1+ (aref (car base) 1)))))

(defun nl-safe-mock-ptr (len)
  "Return a fat pointer over a fresh LEN-byte mock allocation.
Test/demo convenience; the raw construction happens inside the
library's own unsafe kernel (`nl-safe--ptr-make')."
  (nl-safe--ptr-make (nl-safe-mock-alloc len) len 0))

;;;; Fat pointers (Doc 170 section 4) ----------------------------------

(defun nl-safe--ptr-make (base len generation)
  "Raw fat pointer constructor: [nl--ptr BASE LEN GENERATION].
Unsafe kernel entry; user code goes through `nl-ptr-make' inside
`nl-unsafe'."
  (vector 'nl--ptr base len generation))

(defmacro nl-ptr-make (base len generation)
  "Construct a fat pointer over BASE with LEN and GENERATION.
Unsafe primitive: under (nl-strict t), using it outside an
`nl-unsafe' block is an expansion-time error (Doc 170 section 4.3)."
  (if nl--strict
      (error "nl-ptr-make: only allowed inside `nl-unsafe' under (nl-strict t)")
    `(nl-safe--ptr-make ,base ,len ,generation)))

(defun nl-ptr-p (object)
  "Return non-nil when OBJECT is a fat pointer."
  (and (vectorp object)
       (= (length object) 4)
       (eq (aref object 0) 'nl--ptr)))

(defun nl-ptr-len (ptr)
  "Return the length in bytes of the fat pointer PTR."
  (unless (nl-ptr-p ptr)
    (signal 'nl-type-error (list 'nl-ptr-len ptr)))
  (aref ptr 2))

(defun nl-safe--ptr-validate (ptr offset size op)
  "Validate the SIZE-byte access at OFFSET through PTR for operation OP.
Checks, in order: PTR is a fat pointer (`nl-type-error'), the access
is within bounds -- OFFSET >= 0, SIZE >= 0, OFFSET + SIZE <= LEN --
\(`nl-ptr-bounds-error'), and the backend's current generation matches
the pointer's (`nl-ptr-generation-error'; skipped when the backend
returns nil).  Bounds and generation failures are recorded in
`nl-safe--violation-log' when logging is on."
  (unless (nl-ptr-p ptr)
    (signal 'nl-type-error (list op ptr)))
  (let ((len (aref ptr 2)))
    (when (or (< offset 0) (< size 0) (> (+ offset size) len))
      (nl-safe--log-violation
       (list :kind 'bounds :op op :offset offset :size size :len len))
      (signal 'nl-ptr-bounds-error
              (list :op op :offset offset :size size :len len)))
    (let ((current (funcall nl-safe-ptr-backend 'generation (aref ptr 1)))
          (expected (aref ptr 3)))
      (when (and current (not (= current expected)))
        (nl-safe--log-violation
         (list :kind 'generation :op op :expected expected :actual current))
        (signal 'nl-ptr-generation-error
                (list :op op :expected expected :actual current))))))

(defun nl-safe--ptr-ref-u8 (ptr offset)
  "Checked u8 read through PTR at OFFSET."
  (nl-safe--ptr-validate ptr offset 1 'nl-ptr-ref-u8)
  (funcall nl-safe-ptr-backend 'ref-u8 (aref ptr 1) offset))

(defun nl-safe--ptr-set-u8 (ptr offset value)
  "Checked u8 write of VALUE through PTR at OFFSET."
  (nl-safe--ptr-validate ptr offset 1 'nl-ptr-set-u8)
  (unless (and (integerp value) (>= value 0) (<= value 255))
    (signal 'nl-type-error (list 'nl-ptr-set-u8 value)))
  (funcall nl-safe-ptr-backend 'set-u8 (aref ptr 1) offset value))

(defun nl-safe--ptr-ref-u64 (ptr offset)
  "Checked u64 (little-endian) read through PTR at OFFSET."
  (nl-safe--ptr-validate ptr offset 8 'nl-ptr-ref-u64)
  (funcall nl-safe-ptr-backend 'ref-u64 (aref ptr 1) offset))

(defun nl-safe--ptr-slice (ptr offset len)
  "Checked derived pointer: LEN bytes of PTR starting at OFFSET.
The derived range is validated against the parent (OFFSET + LEN <=
parent LEN), so a slice can only narrow, never widen.  The derived
pointer inherits the parent's generation."
  (nl-safe--ptr-validate ptr offset len 'nl-ptr-slice)
  (vector 'nl--ptr
          (funcall nl-safe-ptr-backend 'sub-base (aref ptr 1) offset)
          len
          (aref ptr 3)))

(defun nl-safe--ptr-slice-unchecked (ptr offset len)
  "Unchecked derived pointer; expansion target when checks are off."
  (vector 'nl--ptr
          (funcall nl-safe-ptr-backend 'sub-base (aref ptr 1) offset)
          len
          (aref ptr 3)))

(defmacro nl-ptr-ref-u8 (ptr offset)
  "Read the byte at OFFSET through the fat pointer PTR.
Bounds- and generation-checked while `nl-safe--enabled'; expands to
the plain backend access when it is nil at expansion time."
  (if nl-safe--enabled
      `(nl-safe--ptr-ref-u8 ,ptr ,offset)
    `(funcall nl-safe-ptr-backend 'ref-u8 (aref ,ptr 1) ,offset)))

(defmacro nl-ptr-set-u8 (ptr offset value)
  "Write byte VALUE at OFFSET through the fat pointer PTR.
Bounds- and generation-checked while `nl-safe--enabled'; expands to
the plain backend access when it is nil at expansion time."
  (if nl-safe--enabled
      `(nl-safe--ptr-set-u8 ,ptr ,offset ,value)
    `(funcall nl-safe-ptr-backend 'set-u8 (aref ,ptr 1) ,offset ,value)))

(defmacro nl-ptr-ref-u64 (ptr offset)
  "Read the little-endian u64 at OFFSET through the fat pointer PTR.
Bounds- and generation-checked while `nl-safe--enabled'; expands to
the plain backend access when it is nil at expansion time."
  (if nl-safe--enabled
      `(nl-safe--ptr-ref-u64 ,ptr ,offset)
    `(funcall nl-safe-ptr-backend 'ref-u64 (aref ,ptr 1) ,offset)))

(defmacro nl-ptr-slice (ptr offset len)
  "Derive a LEN-byte fat pointer at OFFSET into PTR.
The derived range is clamped to the parent's (checked while
`nl-safe--enabled'); expands to the unchecked constructor when it is
nil at expansion time."
  (if nl-safe--enabled
      `(nl-safe--ptr-slice ,ptr ,offset ,len)
    `(nl-safe--ptr-slice-unchecked ,ptr ,offset ,len)))

;;;; Unsafe boundary (Doc 170 section 4.3) ------------------------------

(defconst nl-safe-unsafe-primitives
  '(nl-ptr-make
    nl-safe--ptr-make
    syscall-direct
    nl-ffi-call
    alloc-bytes
    free-bytes
    frame-alloc
    ptr-read-u8
    ptr-write-u8
    ptr-read-u16
    ptr-write-u16
    ptr-read-u32
    ptr-write-u32
    ptr-read-u64
    ptr-write-u64)
  "Inventory of unsafe primitives (Doc 170 section 4.3).
These are the only operations that may mint or dereference raw
memory; anything built on top must go through fat pointers.  The
acceptance condition caps this list at 20 entries (CI-tested).  Only
`nl-ptr-make' is expansion-gated by this package today: the others
are standalone runtime primitives, and gating their call sites is the
`nl-check' inventory report's job (Doc 170 section 10, follow-up).")

(defun nl-safe--unsafe-rewrite (form)
  "Rewrite `nl-ptr-make' calls in FORM to the raw constructor.
Quoted forms are not descended into."
  (cond
   ((not (consp form)) form)
   ((eq (car form) 'quote) form)
   ((eq (car form) 'nl-ptr-make)
    (cons 'nl-safe--ptr-make (nl-safe--unsafe-rewrite-seq (cdr form))))
   (t (nl-safe--unsafe-rewrite-seq form))))

(defun nl-safe--unsafe-rewrite-seq (form)
  "Map `nl-safe--unsafe-rewrite' over the cons tree FORM."
  (if (consp form)
      (cons (nl-safe--unsafe-rewrite (car form))
            (nl-safe--unsafe-rewrite-seq (cdr form)))
    form))

(defmacro nl-unsafe (&rest body)
  "Mark BODY as an unsafe block; return the last form's value.
Inside the block `nl-ptr-make' is allowed even under (nl-strict t):
the block rewrites it to the raw constructor before the strict gate
in the `nl-ptr-make' macro could fire.  Keep these blocks small and
few -- `nl-check' (Doc 170 section 10) tracks their count in CI."
  `(progn ,@(mapcar #'nl-safe--unsafe-rewrite body)))

(provide 'nl-safe)

;;; nl-safe.el ends here
