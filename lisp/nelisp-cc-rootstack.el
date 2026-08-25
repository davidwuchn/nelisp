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
;; Main-thread storage is driver-owned BSS, not arena memory:
;;   (data-addr nl_rootstack_top)   = next free entry (0 = uninitialised)
;;   (data-addr nl_rootstack_region)= 131072 fixed 32-byte entries
;; BSS is outside sweep/compaction, so handles stay stable.  Each entry is
;; marked via `nl_gc_mark_slot' exactly like ctx/result/out.
;;
;; Doc 199 Tier 3b extends the same API to Tier-3a workers.  A registered
;; worker uses env+120 as its private top and [env+4096, top) as its private
;; reserve.  `nl_thread_registry' is a fixed driver-owned BSS table:
;;   +0 count, +8 reserved, +16.. 64 entries of {env, published-top} (16B).
;; Reserve/release publish the new top with a SeqCst CAS store.  The marker
;; takes a SeqCst snapshot and reuses `nl_gc_mark_rootstack_walk'; collection
;; remains stop-the-world at the Tier-3b barrier, not concurrent.
;;
;; API (consumed by Stage 3):
;;   nl_root_mark ENV        -> current top (a release marker; LIFO)
;;   nl_root_reserve ENV     -> reserve one zeroed 32B slot, return addr
;;   nl_root_release ENV M   -> restore top to marker M (pop the frame)

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
    ;; Fixed worker registry.  ADD is parent-only during the spawn phase, and
    ;; publishes count only after the entry is complete.  CLEAR is likewise
    ;; parent-only after every worker has joined.  Runtime values stay in
    ;; helper arguments: cc-unit locals cannot carry them across calls.
    (defun nl_thread_registry_entry (i)
      (+ (data-addr nl_thread_registry) (+ 16 (* i 16))))
    (defun nl_thread_registry_add_at (env i)
      (if (>= i 64) (- 0 1)
        (seq
         (ptr-write-u64 (nl_thread_registry_entry i) 0 env)
         (ptr-write-u64 (nl_thread_registry_entry i) 8
                        (ptr-read-u64 env 120))
         (ptr-write-u64 (data-addr nl_thread_registry) 0 (+ i 1))
         i)))
    (defun nl_thread_registry_add (env)
      (nl_thread_registry_add_at
       env (ptr-read-u64 (data-addr nl_thread_registry) 0)))
    (defun nl_thread_registry_clear ()
      (ptr-write-u64 (data-addr nl_thread_registry) 0 0))
    (defun nl_thread_registry_find_from (env i count)
      (if (>= i count) 0
        (if (= (ptr-read-u64 (nl_thread_registry_entry i) 0) env)
            (nl_thread_registry_entry i)
          (nl_thread_registry_find_from env (+ i 1) count))))
    (defun nl_thread_registry_find (env)
      (nl_thread_registry_find_from
       env 0 (ptr-read-u64 (data-addr nl_thread_registry) 0)))
    ;; The AOT DSL has no separate atomic-store operation.  A successful
    ;; SeqCst compare-exchange is the required atomic publication store; the
    ;; fetch-add by zero supplies its SeqCst expected value / marker load.
    (defun nl_thread_registry_store_top (entry top)
      (if (= (atomic-compare-exchange
              (+ entry 8) (atomic-fetch-add (+ entry 8) 0) top)
             1)
          top
        (nl_thread_registry_store_top entry top)))
    (defun nl_root_mark_at (env entry)
      (if (= entry 0)
          (ptr-read-u64 (data-addr nl_rootstack_top) 0)
        (ptr-read-u64 env 120)))
    (defun nl_root_mark (env)
      (nl_root_mark_at env (nl_thread_registry_find env)))
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
    (defun nl_root_reserve_private (env entry slot)
      (if (= slot 0) 0
        (seq
         (ptr-write-u64 slot 0 0)
         (ptr-write-u64 (+ slot 8) 0 0)
         (ptr-write-u64 (+ slot 16) 0 0)
         (ptr-write-u64 (+ slot 24) 0 0)
         (ptr-write-u64 env 120 (+ slot 32))
         (nl_thread_registry_store_top entry (+ slot 32))
         slot)))
    (defun nl_root_reserve_at (env entry)
      (if (= entry 0)
          (seq
           (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0)
               (nl_rootstack_init) 0)
           (nl_root_reserve_slot
            (ptr-read-u64 (data-addr nl_rootstack_top) 0)))
        (nl_root_reserve_private env entry (ptr-read-u64 env 120))))
    (defun nl_root_reserve (env)
      (nl_root_reserve_at env (nl_thread_registry_find env)))
    (defun nl_root_release_at (env entry marker)
      (if (= entry 0)
          (ptr-write-u64 (data-addr nl_rootstack_top) 0 marker)
        (seq
         (ptr-write-u64 env 120 marker)
         (nl_thread_registry_store_top entry marker)
         0)))
    (defun nl_root_release (env marker)
      (nl_root_release_at env (nl_thread_registry_find env) marker))
    ;; GC: walk [region, top) in 32-byte steps, mark each slot like a root.
    (defun nl_gc_mark_rootstack_walk (p end)
      (if (>= p end) 0
          (seq (extern-call nl_gc_mark_slot p)
               (nl_gc_mark_rootstack_walk (+ p 32) end))))
    (defun nl_gc_mark_rootstack ()
      (if (= (ptr-read-u64 (data-addr nl_rootstack_top) 0) 0) 0
          (nl_gc_mark_rootstack_walk (data-addr nl_rootstack_region)
                                     (ptr-read-u64 (data-addr nl_rootstack_top) 0))))
    ;; Tier 3b: marker-side enumeration of every published private reserve.
    ;; The barrier has stopped workers before this runs; the atomic top load is
    ;; still paired with reserve/release publication so the API is explicit.
    (defun nl_gc_mark_thread_roots_one (env top)
      (if (= env 0) 0
        (nl_gc_mark_rootstack_walk (+ env 4096) top)))
    (defun nl_gc_mark_thread_roots_from (i count)
      (if (>= i count) 0
        (seq
         (nl_gc_mark_thread_roots_one
          (ptr-read-u64 (nl_thread_registry_entry i) 0)
          (atomic-fetch-add (+ (nl_thread_registry_entry i) 8) 0))
         (nl_gc_mark_thread_roots_from (+ i 1) count))))
    (defun nl_gc_mark_thread_roots ()
      (nl_gc_mark_thread_roots_from
       0 (ptr-read-u64 (data-addr nl_thread_registry) 0))))
  "AOT source for the Doc 152 §11.37 Stage 2 dynamic root stack.

Lazy-inits on the first main-thread `nl_root_reserve'.  Stage-3 evaluator callers use
the returned mutable entry directly as their eval/function result slot and
restore a saved `nl_root_mark' on every status path.  Tier-3b workers select
their registered private reserve by EvalCtx address.  See the Commentary for
the storage layout and soundness rationale.")

(provide 'nelisp-cc-rootstack)

;;; nelisp-cc-rootstack.el ends here
