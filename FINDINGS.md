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

---

2026-07-04 second follow-on: form-boundary classification experiments

Scope

Ran the two sharper classification experiments requested for the full vendor
REPL replay of the 10-file SMIE chain plus full `progmodes/sh-script.el`.
Because this sandbox cannot write into the sibling `nelisp-emacs-lib` checkout,
the replay was run by overriding `NELISP_ROOT` / `NELISP_BIN` to point at this
worktree's freshly built `target/nelisp`, and by overriding
`VENDOR_SOURCE_CACHE_DIR` to `/tmp`.  Every reader run was wrapped in
`timeout 120`.

Experiment 1: skip boundary reclaim

Temporary patch: `nl_boundary_maybe_reclaim` returned `0` unconditionally.

Result: FAIL.  The replay still SIGSEGVed at the same sentinel:

- `exit=11`
- `sentinel="form-start:sh-script.el:122:count=10"`

Classification from experiment 1: the crash is not caused by
`nl_boundary_maybe_reclaim` rewinding the Stage-5 bump cursor and freeing the
grammar state.

Experiment 2: huge form-boundary GC threshold

Temporary patch: the initial GC trigger at `268435560` was set from 16 MiB to
1 TiB (`1099511627776`), making the normal form-boundary mark/sweep trigger
unreachable for this replay.

Result: FAIL.  The replay still SIGSEGVed at the same sentinel:

- `exit=11`
- `sentinel="form-start:sh-script.el:122:count=10"`

Classification from experiment 2: the crash is not explained by the normal
form-boundary threshold collection sweeping an unrooted in-flight grammar value
during or immediately after form 122.

Current classification

Both decisive gates failed to move the crash, so the current full replay
failure is neither the Stage-5 boundary reclaim path nor the ordinary
threshold-triggered `nl_gc_collect_form_boundary` path.  This is consistent
with the prior boot-collection-disable negative result, but sharper: even
removing the per-form reclaim call and separately preventing the threshold
collection leaves the same form122 crash.

The implicated live structure is still the SMIE grammar construction result
graph built by `smie-bnf->prec2` / `smie-prec2->grammar`: nested alists,
hash-tables, and shared mutable cons cells churned by `setcar` / `setcdr` /
`puthash`.  Given these two negatives, the next likely root gap is not a
form-boundary reclaim/collection scratch slot such as `func_slot` or `out_slot`;
it is more likely an intra-form allocation/mutation path in the hash-table /
alist graph, or a replay-wrapper status/write allocation that exposes stale
state before the grammar form starts.

Recommended next step

Instrument mutation and allocation counters around the status wrapper and the
first allocator/user inside form 122 rather than adding more roots to
`nl_gc_mark_roots`.  Useful probes:

- Count calls to `nl_boundary_maybe_reclaim` and
  `nl_gc_collect_form_boundary` between sh-script forms 121 and 122 to confirm
  the negative classification in the unpatched build.
- Instrument `setcar`, `setcdr`, `puthash`, and hash-table rehash/allocation
  while evaluating form 122, because the synthetic "new symbol + forced
  boundary GC" negative rules out generic symbol interning and points at the
  SMIE graph's specific mutable hash/alist allocation pattern.

---

2026-07-04 third follow-on: `define-derived-mode` "misfold" retraction +
minimal repro of the real defect

Scope

Follow-up to the merge-39e45d90 residual: "expanding UNMODIFIED vendor
derived.el's `define-derived-mode` misfolds sibling forms (`use-local-map`/
`set-syntax-table`/`(setq local-abbrev-table ...)`) into the preceding
`delay-mode-hooks` tail." Built `make standalone-reader` fresh on
`fix/derived-sibling-fold` (off `main` @ 39e45d90) and reproduced against
the real, unmodified
`nelisp-emacs-lib/vendor/emacs-lisp/emacs-lisp/derived.el` (read-only), not
a hand-copied excerpt.

Retraction

There is no backquote/macroexpansion defect. Loading the byte-identical
vendor `define-derived-mode` text and calling
`(macroexpand-1 '(define-derived-mode my-m nil "M" "doc"))`, and separately
a two-mode parent chain (`(define-derived-mode dm-child-a nil "A")` then
`(define-derived-mode dm-child-b dm-child-a "B")`, exercising the non-nil
`,(when parent \`(progn ...))` branch with its own nested
`,(when declare-syntax \`(let ...))` / `,(when declare-abbrev \`(unless
...))` sub-templates two levels deep), always printed a fully correct
expansion: `use-local-map`, `set-syntax-table`, and
`(setq local-abbrev-table ...)` appear as proper top-level siblings inside
`delay-mode-hooks`, exactly matching real Emacs's expansion shape. With an
accurate helper-function stub environment, `(fboundp 'dm-child-a)`,
`(fboundp 'dm-child-b)`, `(commandp 'dm-child-a)`, `(commandp
'dm-child-b')` are all `t` -- the vendor macro works end-to-end on this
reader unmodified.

Root cause of the original observation

The apparent "misfold" was a session artifact, not a reader defect in the
area under investigation:

1. An ad hoc test stub used during triage, `(defun define-abbrev-table
   (&rest _) nil)`, is not faithful to real Emacs: real `define-abbrev-table`
   side-effects a `set` on its table-name argument. Vendor derived.el relies
   on exactly that side effect: `(defvar CHILD-abbrev-table (progn
   (define-abbrev-table 'CHILD-abbrev-table nil) CHILD-abbrev-table))` reads
   back the symbol it just (in real Emacs) bound. With the inert stub, that
   read-back is a genuine reference to a still-unbound variable.
2. That triggered a second, real, and more interesting defect: an
   unbound-variable reference partway through evaluating a compound
   top-level form silently and uncatchably abandons the *rest of that form*,
   with no diagnostic and no `condition-case`-catchable signal, letting the
   driver loop move on to the next top-level form as if nothing happened.
   Because `use-local-map`/`set-syntax-table`/`setq local-abbrev-table`
   come *after* the abbrev-table `defvar` inside the same `(defun CHILD ()
   ...)` body, they silently never ran when the CLI actually installed the
   mode function (as opposed to only previewing it via `macroexpand-1`,
   which never evaluates the body) -- producing symptoms (missing/absorbed-
   looking trailing forms) that read like a structural cons misfold but
   were actually a truncated evaluation.

Minimal repro of the real defect (decoupled from derived.el entirely)

```elisp
(progn (defvar v2 (progn 1 v2)) (defun f2 () 42))
(prin1 (fboundp (quote f2)))
(terpri)
```

`./target/nelisp --load` prints `nil` for the `fboundp` (then `t` from the
last form's auto-echo) -- `f2` was never defined, silently, exit code 0, no
stderr output. The variable need not be self-referencing; any unbound
reference reproduces it: `(progn (defvar v3 totally-unbound-name) (defun f3
() 42))` also leaves `f3` unbound. Wrapping the protected form in
`condition-case` does not catch it either (confirmed: the whole
`condition-case` top-level form is itself silently abandoned), so this is
not a normal signaled Elisp condition escaping uncaught -- it bypasses the
catch/throw machinery entirely.

By contrast, an outright `void-function` call (undefined symbol in head
position) correctly halts the process with `nelisp: uncaught error:
void-function: (...)` and a non-zero exit -- so top-level error reporting
is not blanket-broken, only this specific path.

Where this lives (not fixed -- see "why not fixed" below)

`scripts/nelisp-standalone-build.el`:
- `nl_eval_source_all` (~line 9958-10010, the `--eval`/`--load` top-level
  driver) only calls `nl_eval_source_report_error` (the
  "nelisp: uncaught error: ..." printer, ~line 9911-9956) when the per-form
  `nelisp_eval_call` return code (`form_rc`) is nonzero *and* the M6 stash
  flag @268435472 is nonzero (a genuine signal/throw was stashed). The
  surrounding comment (line ~9992-10004) documents this as deliberate: "a
  flag==0 non-zero rc is treated as before this fix (silently continues) so
  inline substrate loading is unaffected." The unbound-variable path
  reproduced above evidently does not stash the flag the same way a
  `bf_signal`/`bf_error` call does (see those at ~line 5888-5905), so it
  falls into the already-accepted "silently continue" branch.
- `bf_load_eval_loop` (~line 5963-5988, backing the `load` primitive) does
  not check `form_rc`/the flag at all between forms, unconditionally
  looping to the next top-level form regardless of outcome.
- `nl_eval_inner`/`nelisp_eval_call` (~line 2522 onward) is the shared
  variable-lookup + dispatch core; finding exactly why a bare unbound-symbol
  evaluation fails to route through the same stash path as
  `bf_signal`/`bf_error` requires tracing this dispatcher, which is
  intertwined with the GC safepoint/arena-mark protocol documented in the
  large comment block just above `nelisp-standalone--shim-source`
  (~line 2465-2520).

Why not fixed here

This is exactly the class of finding this investigation's brief said to
STOP on rather than patch blind: the real defect is in the shared
eval/signal-flag substrate (touching the same rc/flag protocol used by GC
safepoints and every builtin's error path), not a small, local
list-construction fix in the backquote engine
(`nelisp--bq-expand`/`nelisp--bq-build` in
`scripts/nelisp-stdlib-prelude.el`), which is where the original report
pointed and where this session confirmed there is nothing to fix.

Regression guard added

`make standalone-reader-derived-mode-shape-smoke` (self-contained, no
cross-repo vendor path) pins down the specific backquote shape at stake --
single-comma list element, nil-vs-nested-`progn` branch through two levels
of comma-escaped nested backquote, trailing plain siblings -- proving via
`macroexpand-1`/`equal` that the engine builds proper sibling lists in both
the nil-branch and populated-branch cases. All pre-existing reader smokes
(`standalone-reader-test`, `-load-smoke`, `-fmt-smoke`,
`-prelude-equal-reload-smoke`, `-nested-backquote-macro-smoke`) plus the
scratchpad's saved 43-form REPL error-tolerance replay were re-run and are
byte-for-byte unchanged.

Recommended next step

Treat "unbound-variable reference silently and uncatchably truncates the
enclosing top-level form" as its own tracked defect, independent of
derived.el. Trace `nl_eval_inner`'s symbol-evaluation arm to find why it
does not reach the same `bf_signal`-style stash as an explicit `(error
...)`/`(signal ...)` call, then decide whether `nl_eval_source_all`'s
`flag==0` tolerance and `bf_load_eval_loop`'s missing rc check should also
change once the stash itself is fixed. Do this as a dedicated GC/evaluator-
substrate investigation, not folded into a "fix the backquote engine" task.
