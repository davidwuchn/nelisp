;;; nelisp-cc-sf-unwind-protect.el --- AOT nl_sf_unwind_protect swap  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; AOT replacement for the `sf_unwind_protect' Rust body in
;; `build-tool/src/eval/special_forms.rs'.  The Rust body was:
;;
;;   fn sf_unwind_protect(args: &Sexp, env: &mut Env) -> Result<Sexp, EvalError> {
;;       let parts = list_elements(args)?;
;;       expect_min_len(&parts, "unwind-protect", 1)?;
;;       let body_result = eval(&parts[0], env);
;;       let mut cleanup_err: Option<EvalError> = None;
;;       for cleanup in parts.iter().skip(1) {
;;           if let Err(e) = eval(cleanup, env) {
;;               if cleanup_err.is_none() {
;;                   cleanup_err = Some(e);
;;               }
;;           }
;;       }
;;       cleanup_err.map_or(body_result, Err)
;;   }
;;
;; `args' is the raw unevaluated arg list `(BODYFORM CLEANUP...)'.
;;   car(args)  = BODYFORM — the protected expression.
;;   cdr(args)  = CLEANUP list — zero or more cleanup forms.
;;
;; Semantics: BODYFORM is evaluated first.  Then every CLEANUP form
;; is evaluated unconditionally.  If BODYFORM completed normally, the
;; first cleanup error is returned with the usual stashed signal data.
;; If BODYFORM already stashed an error, cleanup errors are silently
;; discarded so the body error remains the one reported.  The final
;; return code is either the first cleanup error on a normal body, or
;; the body's rc (0=Ok or 1=Err with stash in `nelisp--last-signal-data').
;;
;; Key: `nelisp_eval_call' stashes errors into `nelisp--last-signal-data'
;; on rc=1.  Cleanup eval after a normal body uses `nelisp_eval_call' into
;; a scratch slot so cleanup errors are stashed and visible to condition-case
;; / the diagnostic printer.  Cleanup eval after a body error snapshots the
;; M6 stash TAG/VAL slots, uses `nl_eval_is_truthy' as a discard eval, and
;; restores the body stash before continuing.
;;
;; ABI externs used:
;;   nl_cons_car_ptr: (*const Sexp) → i64   (= &car of cons, or 0 for non-Cons)
;;   nl_cons_cdr_ptr: (*const Sexp) → i64   (= &cdr of cons, or 0 for non-Cons)
;;   nl_sexp_clone_into: (*const Sexp, *mut Sexp) → ()
;;   nelisp_eval_call: (*const Sexp, *mut c_void, *mut Sexp) → i64
;;     Standard eval entry; writes result to *out on rc=0, stashes error to
;;     `nelisp--last-signal-data' on rc=1.
;;   nl_eval_is_truthy: (*const Sexp, *mut c_void) → i64
;;     Evals form; returns 1/0 for truthy/nil, -1 on error (error DISCARDED —
;;     does NOT write to `nelisp--last-signal-data').
;;
;; Slot usage of the public ABI `(args, env, out, _pad)':
;;   args: input list, immutable.
;;   env:  `&mut Env'.
;;   out:  result slot — holds body result on success; unchanged on error.
;;   _pad: unused alignment pad.
;;
;; Alignment: every defun has even arity (4 or 6) and every extern-call
;; appears as argument 0 at its call site so rsp ≡ 0 mod 16 at the call.
;;
;; Structure (12 defuns, seq form):
;;   Cleanup walk (normal body: propagates cleanup error;
;;                 body error: discards cleanup errors, preserves body stash):
;;   nl_sf_uw_cleanup_done  (truthy cdr body-rc env out _pad6)  — arity 6
;;   nl_sf_uw_cleanup_evaled (cleanup-rc cdr body-rc env out _pad6) — arity 6
;;   nl_sf_uw_do_cleanup_preserve (scratch car cdr body-rc env out) — arity 6
;;   nl_sf_uw_restore_after_discard (truthy tag-save val-save cdr body-rc env out _pad8) — arity 8
;;   nl_sf_uw_do_cleanup_discard (tag-save val-save car cdr body-rc env out _pad8) — arity 8
;;   nl_sf_uw_do_cleanup    (car cdr body-rc env out _pad6)     — arity 6
;;   nl_sf_uw_got_cdr       (cdr cleanup body-rc env out _pad6) — arity 6
;;   nl_sf_uw_cleanup       (cleanup body-rc env out _pad5 _pad6) — arity 6
;;   nl_sf_uw_with_cleanup  (cleanup body-rc env out)           — arity 4
;;   Body + init:
;;   nl_sf_uw_after_body    (body-rc args env out)              — arity 4
;;   nl_sf_uw_got_car       (car args env out)                  — arity 4
;;   nl_sf_unwind_protect   (args env out _pad)                 — arity 4 (public)

;;; Code:

(defconst nelisp-cc-sf-unwind-protect--source
  '(seq

    ;;--- Cleanup walk ---

    ;; After nl_eval_is_truthy on one cleanup form: truthy is discarded
    ;; (we only care that cleanup ran, not its value or error).
    ;; Recurse on remaining cleanup forms.
    ;; Arity 6 (even): truthy, cdr, body-rc, env, out, _pad6.
    (defun nl_sf_uw_cleanup_done (truthy cdr body-rc env out _pad6)
      (nl_sf_uw_cleanup cdr body-rc env out 0 0))

    ;; After nelisp_eval_call on a cleanup form for a normal body:
    ;; rc=0 continues to the next cleanup, rc=1 propagates the stashed
    ;; cleanup error and leaves *out holding the protected body's value.
    ;; Arity 6 (even): cleanup-rc, cdr, body-rc, env, out, _pad6.
    (defun nl_sf_uw_cleanup_evaled (cleanup-rc cdr body-rc env out _pad6)
      (if (= cleanup-rc 0)
          (nl_sf_uw_cleanup cdr body-rc env out 0 0)
        cleanup-rc))

    ;; scratch = temporary result slot.  Eval this cleanup form via
    ;; nelisp_eval_call so cleanup errors are stashed normally.
    ;; Arity 6 (even): scratch, car, cdr, body-rc, env, out.
    (defun nl_sf_uw_do_cleanup_preserve (scratch car cdr body-rc env out)
      (nl_sf_uw_cleanup_evaled
       (extern-call nelisp_eval_call car env scratch)
       cdr body-rc env out 0))

    ;; After discard-evaluating a cleanup while the body already errored,
    ;; restore the saved M6 signal stash and continue the cleanup walk.
    ;; Arity 8 (even): truthy, tag-save, val-save, cdr, body-rc, env, out, _pad8.
    (defun nl_sf_uw_restore_after_discard
        (truthy tag-save val-save cdr body-rc env out _pad8)
      (seq
       (nl_sexp_clone_into tag-save 268435480)
       (nl_sexp_clone_into val-save 268435512)
       (ptr-write-u64 268435472 0 1)
       (dealloc-bytes tag-save 32 8)
       (dealloc-bytes val-save 32 8)
       (nl_sf_uw_cleanup_done truthy cdr body-rc env out 0)))

    ;; Discard-evaluate cleanup for an already failing body.  The caller
    ;; saved the body stash before this call; restore_after_discard puts it
    ;; back even if nl_eval_is_truthy stashed the cleanup error internally.
    ;; Arity 8 (even): tag-save, val-save, car, cdr, body-rc, env, out, _pad8.
    (defun nl_sf_uw_do_cleanup_discard
        (tag-save val-save car cdr body-rc env out _pad8)
      (nl_sf_uw_restore_after_discard
       (extern-call nl_eval_is_truthy car env)
       tag-save val-save cdr body-rc env out 0))

    ;; car = nl_cons_car_ptr(cleanup) already fetched as first arg.
    ;; If body was normal, evaluate cleanup through nelisp_eval_call so
    ;; cleanup errors propagate.  If body already errored, use the discard
    ;; path so the body stash remains intact.
    ;; Arity 6 (even): car, cdr, body-rc, env, out, _pad6.
    (defun nl_sf_uw_do_cleanup (car cdr body-rc env out _pad6)
      (if (= body-rc 0)
          (let* ((scratch (alloc-bytes 32 8)))
            (nl_sf_uw_do_cleanup_preserve scratch car cdr body-rc env out))
        (let* ((tag-save (alloc-bytes 32 8))
               (val-save (alloc-bytes 32 8)))
          (seq
           (nl_sexp_clone_into 268435480 tag-save)
           (nl_sexp_clone_into 268435512 val-save)
           (nl_sf_uw_do_cleanup_discard
            tag-save val-save car cdr body-rc env out 0)))))

    ;; cdr = nl_cons_cdr_ptr(cleanup) already fetched as first arg.
    ;; Get car(cleanup) (extern-call FIRST ✓) and delegate to do_cleanup.
    ;; Arity 6 (even): cdr, cleanup, body-rc, env, out, _pad6.
    (defun nl_sf_uw_got_cdr (cdr cleanup body-rc env out _pad6)
      (nl_sf_uw_do_cleanup
       (extern-call nl_cons_car_ptr cleanup)
       cdr body-rc env out 0))

    ;; Recursive cleanup walk entry.
    ;; If cleanup is Nil (tag 0): all forms done, return body-rc.
    ;; Otherwise: get cdr first (extern-call FIRST ✓), then car, then eval.
    ;; Arity 6 (even): cleanup, body-rc, env, out, _pad5, _pad6.
    (defun nl_sf_uw_cleanup (cleanup body-rc env out _pad5 _pad6)
      (if (= (sexp-tag cleanup) 0)
          body-rc
        (nl_sf_uw_got_cdr
         (extern-call nl_cons_cdr_ptr cleanup)
         cleanup body-rc env out 0)))

    ;; Bridge arity-4 → arity-6 cleanup entry.
    ;; Arity 4 (even): cleanup, body-rc, env, out.
    (defun nl_sf_uw_with_cleanup (cleanup body-rc env out)
      (nl_sf_uw_cleanup cleanup body-rc env out 0 0))

    ;;--- Body + init ---

    ;; body-rc = result of nelisp_eval_call(body, env, out).
    ;; On rc=0: *out holds body result; nelisp--last-signal-data untouched.
    ;; On rc=1: nelisp--last-signal-data holds body error; *out unchanged.
    ;; Either way: get cleanup list = cdr(args) (extern-call FIRST ✓), run cleanup.
    ;; Arity 4 (even): body-rc, args, env, out.
    (defun nl_sf_uw_after_body (body-rc args env out)
      (nl_sf_uw_with_cleanup
       (extern-call nl_cons_cdr_ptr args)
       body-rc env out))

    ;; car = nl_cons_car_ptr(args) already fetched as first arg.
    ;; Eval body form via nelisp_eval_call (extern-call FIRST ✓).
    ;; Arity 4 (even): car, args, env, out.
    (defun nl_sf_uw_got_car (car args env out)
      (nl_sf_uw_after_body
       (extern-call nelisp_eval_call car env out)
       args env out))

    ;; Public entry: nl_sf_unwind_protect(args, env, out, _pad) → i64
    ;; args: *const Sexp = (BODYFORM CLEANUP...).
    ;; env:  *mut c_void = &mut Env.
    ;; out:  *mut Sexp   = result slot (Nil initially from Rust thin shell).
    ;; _pad: unused alignment pad (makes arity 4 = even).
    ;; Returns: 0=Ok (result in *out), 1=Err (body error stashed in env var).
    ;; Empty args (Nil, tag 0) → return 1 (malformed: no body form).
    ;; Otherwise: get body = car(args) (extern-call FIRST ✓), eval, then cleanup.
    ;; Arity 4 (even).
    (defun nl_sf_unwind_protect (args env out _pad)
      (if (= (sexp-tag args) 0)
          1
        (nl_sf_uw_got_car
         (extern-call nl_cons_car_ptr args)
         args env out))))

  "AOT source for `nl_sf_unwind_protect'.

12 defuns (seq form) — CPS chain implementing protected body eval,
unconditional cleanup walk, and final rc selection.  Cleanup errors after a
normal body are propagated via nelisp_eval_call; cleanup errors after a body
error are discarded via nl_eval_is_truthy with explicit M6 stash restore so
the body stash survives.

Entry chain (success path):
  nl_sf_unwind_protect
  → (car(args) FIRST) → nl_sf_uw_got_car
  → (nelisp_eval_call body FIRST) → nl_sf_uw_after_body
  → (cdr(args) FIRST) → nl_sf_uw_with_cleanup
  → nl_sf_uw_cleanup
    Nil: return body-rc
    Cons: → (cdr(cleanup) FIRST) → nl_sf_uw_got_cdr
      → (car(cleanup) FIRST) → nl_sf_uw_do_cleanup
        body-rc=0:
          → (nelisp_eval_call cleanup FIRST) → nl_sf_uw_cleanup_evaled
          → rc=0 recurse, rc=1 return cleanup rc
        body-rc=1:
          → save body stash TAG/VAL
          → (nl_eval_is_truthy cleanup FIRST) → nl_sf_uw_restore_after_discard
          → restore body stash TAG/VAL → nl_sf_uw_cleanup_done
          → nl_sf_uw_cleanup (recurse on cdr)

Semantics: cleanup errors after a normal body propagate normally.  Body error
survives in nelisp--last-signal-data through all cleanup steps.  Final rc =
cleanup rc on normal-body cleanup failure, otherwise body-rc.

All defuns have even arity; every extern-call is argument 0 at its
call site → body-entry rsp ≡ 0 mod 16 ✓.

Replaces Rust `sf_unwind_protect' (~14 LOC) with 0 new Rust helpers.
Net Rust delta (including lib.rs extern decl + cc_wrap): ~-8 LOC.")

(provide 'nelisp-cc-sf-unwind-protect)

;;; nelisp-cc-sf-unwind-protect.el ends here
