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
