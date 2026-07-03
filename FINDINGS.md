Root-cause investigation for the standalone reader GC corruption

Summary

The reported failure is real on the current worktree with GC enabled:

- `/tmp/gc-repro.el` fails as `void-function: (car)`.
- Variant B (`garbage-collect` then `car`) fails the same way.
- Variant A (`make-garbage`, then `defun f2`, then `(f2)`) can SIGSEGV.

What was localized

1. The bug is in the tracing GC path, not in freelist reuse or conservative-stack scanning.
2. A concrete DSL hazard is present in the GC hot path today: multi-binding plain `let` forms are used inside `scripts/nelisp-standalone-build.el` in the mark/sweep implementation, despite the repo-local constraint that only `let*` is safe for multi-binding runtime values.
3. Converting the following GC hot-path bindings from plain `let` to `let*` partially repairs the corruption:
   - `nl_gc_mark_slot` vector arm: `(data_ptr len)`
   - `nl_gc_mark_slot` record arm: `(data_ptr len)`
   - `nl_gc_sweep_one`: `(m bt)`
   - `nl_gc_sweep_chunk`: `(hdr end)`

Evidence for item 3

With only those `let*` substitutions applied:

- Main repro (`make-garbage` then `car`) changed from deterministic failure to clean pass in spot checks.
- Variant B (`garbage-collect` then `car`) changed from deterministic failure to clean pass.
- Variant A changed from deterministic crash to an unstable residual failure mode:
  - spot checks passed,
  - but a 10-run loop still produced a SIGSEGV on one iteration.

Additional narrowing

1. The remaining Variant A failure is not a generic mirror lookup miss:
   - `(symbol-function 'f2)` succeeds after the first GC and returns `(closure nil nil 42)`.
   - `(funcall (symbol-function 'f2))` also succeeds.
2. The residual failure is specific to the direct named-call path `(f2)` after the earlier GC-triggering form.
3. Disabling collections around the `defun f2` form avoids the crash:
   - `(make-garbage 300000)`
   - `(nelisp--gc-diag 7)`
   - `(defun f2 () 42)`
   - `(nelisp--gc-diag 8)`
   - `(f2)`
   - This runs cleanly.

Interpretation

- There is at least one real GC bug caused by unsafe multi-binding `let` use inside the GC DSL source.
- Fixing those bindings removes the original builtin-dispatch corruption and the explicit-`garbage-collect` reproducer.
- A second, narrower problem remains around the post-`defun` named-call path after a real form-boundary collection. That path was not reduced to a sound minimal patch within this session.

Failed hypotheses

1. Removing the mirror-specific explicit dispatch walk regressed the original `car` reproducer immediately, so that helper is still needed in the current design.
2. Rewriting that helper to a raw-pointer walk caused all three repros to crash, so that direction was not sound.

Files investigated

- `scripts/nelisp-standalone-build.el`
- `lisp/nelisp-cc-env-lookup-function.el`
- `lisp/nelisp-cc-evalport-combiner-cons.el`
- `lisp/nelisp-cc-sexp-clone-into.el`
- `lisp/nelisp-cc-mirror-lookup-entry.el`
- `lisp/nelisp-cc-mirror-alloc-entry.el`

Recommended next step

Start from the partial `let*` GC hot-path fix above and continue reducing the residual Variant A failure in the direct named-call path only. The most promising next probe is to instrument the boundary collection that runs after `defun f2`, because the remaining crash disappears when that single collection is disabled.

---

2026-07-04 follow-on: SMIE sh-script form-boundary crash

Scope

Investigated the follow-on report on branch `fix/gc-formboundary-rootgap` at
merged main `56352428` / record-offset fix `cee2f9d9` present.  The requested
reproducer is the vendor REPL replay of the minimal SMIE chain plus full
`progmodes/sh-script.el`, with every reader run wrapped in `timeout`.

Confirmed evidence

- `make standalone-reader` succeeded.
- The vendor replay reproducer failed deterministically with SIGSEGV:
  `status=fail exit=11`, sentinel
  `form-start:sh-script.el:122:count=10`.
- The saved replay input showed form 121 is:
  `(defun sh-smie--newline-semi-p ...)`
  and form 122 is the `sh-smie-sh-grammar` computation.
- Enabling poison-on-free with a prepended `(nelisp--gc-diag 1)` file still
  failed at the same form-start sentinel with `exit=11`.
- Running the compact local proof shape directly did not fail:
  loading `tmp-smie-repro/shprefix-120.el` followed by `tmp-smie-repro/pair-proof.el`
  returned `t`.
- Loading `tmp-smie-repro/shprefix-120.el`, then `shform121.el`, then
  `shform122.el` through a small temporary `load` wrapper also returned `t`.

Important negative result

I temporarily rebuilt the reader with collection disabled at boot
(`collect-disabled` slot reported as `1` via `(nelisp--gc-diag 0)`).  The full
vendor REPL replay still SIGSEGVed at the same sh-script form 122 sentinel,
and did so faster (~24s).  This means the current full replay failure is not
explained solely by mark/sweep freeing an unrooted live block during the
form-boundary collection.  Either the replay is exposing an additional
non-GC heap/state corruption, or the user-level diagnosis is missing a
separate prerequisite that is absent from the reduced direct-load proof.

Patch attempts rejected

1. Kept `nl_safepoint_ctx` published until after the boundary collection by
   moving `nl_gc_ctx_pop` out of `nl_driver_eval_published` into the three
   caller loops.  Result: build succeeded, but the reproducer still failed at
   `form-start:sh-script.el:122:count=10`, `exit=11`.
2. Added `nl_gc_mark_published_contexts` to `nl_gc_collect_form_boundary`
   before the direct `nl_gc_collect` call.  Result: build succeeded, but the
   same SIGSEGV remained.
3. Tried to capture a native backtrace with gdb, but ptrace is blocked in the
   sandbox (`Operation not permitted`), so no native stack was available.

Interpretation

The original differential is still useful, but the full replay contains more
top-level forms than the simplified proof: each status `setq` / `nl-write-file`
wrapper is also replayed as a separate form.  The crash happens after the
`form-start` status write and while evaluating the sh-script form 122 line.  A
sound fix was not reached within the small-change budget because the strongest
GC-root hypotheses above did not change the failure, and boot-level collection
disable did not eliminate it.

Recommended next step

Reduce from the saved replay input rather than from `tmp-smie-repro` alone.
Start with `/tmp/nemacs-vendor-repl-standalone-6IjFtB.repl` (or regenerate with
`VENDOR_REPL_KEEP_TEMP=t`) and bisect the prefix between the end of `smie.el`
and `sh-script.el` form 122, preserving the replay wrapper forms.  The next
useful instrumentation target is not just `nl_gc_collect_form_boundary`, but
the `nl-write-file` / status-wrapper path immediately before form 122 and the
first allocator/user of the `smie-bnf->prec2` result graph.
