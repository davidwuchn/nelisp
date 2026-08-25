;;; nelisp-cc-rootstack.el --- Doc 152 §11.37 Stage 2: dynamic root stack  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 152 §11.37 (B+E handle-based root API) Stage 2 — a dynamic root
;; stack so that, in Stage 3, every eval transient box can be parked in a
;; REGISTERED root slot (instead of an unenumerable in-flight C-stack /
;; arena-scratch pointer).  This is the foundation that lets a future
;; mid-form / safepoint GC be SOUND: the marker no longer has to "guess"
;; the live in-flight roots — they are all on this stack.
;;
;; Stage 2 installed this API dormant; Doc 152 Stage 3 activates it from
;; the evaluator.  A reserved entry is mutable 32-byte Sexp storage: eval
;; writes the value into the entry, and the marker revisits that same entry
;; after any allocation/safepoint.  The address of the entry is the handle;
;; callers must not copy its value into unregistered scratch and keep that
;; scratch across a safepoint.
;;
;; Storage is driver-owned BSS, not arena memory:
;;   (data-addr nl_rootstack_top)   = next free entry (0 = uninitialised)
;;   (data-addr nl_rootstack_region)= 32768 fixed 32-byte entries
;; BSS is outside sweep/compaction, so handles stay stable.  Each entry is
;; marked via `nl_gc_mark_slot' exactly like ctx/result/out.
;;
;; API (consumed by Stage 3):
;;   nl_root_mark      -> current top (a release marker; LIFO)
;;   nl_root_reserve   -> lazy-init + reserve one zeroed 32B slot, return addr
;;   nl_root_release M -> restore top to marker M (pop the frame)

;;; Code:

(defconst nelisp-cc-rootstack--source
  '(seq
    ;; Region = FIXED bss array (data-addr nl_rootstack_region); top = bss slot.
    ;; Do NOT mmap (os_alloc_chunk perturbs the arena chunk-growth VA layout ->
    ;; freelist corruption on the next collect, Doc 152 §11.30-33 class).
    ;; top == 0 means uninitialised (bss zero-fill); after init top >= region
    ;; addr (non-zero), so the zero-check is a reliable "not yet armed" gate.
    (defun nl_rootstack_init ()
      (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0)
          (ptr-write-u64 (data-addr nl_rootstack_top) 0 (data-addr nl_rootstack_region))
        0))
    ;; Tier 3a deliberately keeps collection inhibited while clone workers use
    ;; private EvalCtx state.  Marker 1 selects the dormant-rootstack path:
    ;; callers still receive writable scratch slots, but no worker races the
    ;; process-global root-stack top.  A main-thread frame reserved before the
    ;; inhibit retains its aligned marker and is therefore still released.
    ;; Zero remains the historical "not initialised" marker and must still be
    ;; written back by release (the rootstack smoke checks that depth reset).
    (defun nl_root_mark ()
      (if (= (ptr-read-u64 (data-addr nl_gc_loop_ctx) 24) 1)
          1
        (ptr-read-u64 (data-addr nl_rootstack_top) 0)))
    (defun nl_root_depth ()
      (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0) 0
        (sar (- (ptr-read-u64 (data-addr nl_rootstack_top) 0)
                (data-addr nl_rootstack_region))
             5)))
    ;; Reserve one 32-byte slot at top, zero it, bump top, return slot addr.
    (defun nl_root_reserve_slot (slot)
      (if (= slot 0) 0
          (seq (ptr-write-u64 slot 0 0)
               (ptr-write-u64 (+ slot 8) 0 0)
               (ptr-write-u64 (+ slot 16) 0 0)
               (ptr-write-u64 (+ slot 24) 0 0)
               (ptr-write-u64 (data-addr nl_rootstack_top) 0 (+ slot 32))
               slot)))
    (defun nl_root_reserve ()
      (if (= (ptr-read-u64 (data-addr nl_gc_loop_ctx) 24) 1)
          ;; Tier 3a has disabled free-list reuse, so alloc-bytes reaches the
          ;; shared CAS bump path and gives each worker a disjoint 32-byte slot.
          (alloc-bytes 32 8)
        (seq (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0) (nl_rootstack_init) 0)
             (nl_root_reserve_slot (ptr-read-u64 (data-addr nl_rootstack_top) 0)))))
    (defun nl_root_release (marker)
      (if (= marker 1) 0
        (ptr-write-u64 (data-addr nl_rootstack_top) 0 marker)))
    ;; GC: walk [region, top) in 32-byte steps, mark each slot like a root.
    (defun nl_gc_mark_rootstack_walk (p end)
      (if (>= p end) 0
          (seq (extern-call nl_gc_mark_slot p)
               (nl_gc_mark_rootstack_walk (+ p 32) end))))
    (defun nl_gc_mark_rootstack ()
      (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0) 0
          (nl_gc_mark_rootstack_walk (data-addr nl_rootstack_region)
                                     (ptr-read-u64 (data-addr nl_rootstack_top) 0)))))
  "AOT source for the Doc 152 §11.37 Stage 2 dynamic root stack.

Lazy-inits on the first `nl_root_reserve'.  Stage-3 evaluator callers use
the returned mutable entry directly as their eval/function result slot and
restore a saved `nl_root_mark' on every status path.  See the Commentary for
the storage layout and soundness rationale.")

(provide 'nelisp-cc-rootstack)

;;; nelisp-cc-rootstack.el ends here
