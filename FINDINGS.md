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

---

2026-07-04 follow-on: `(org-mode)` practical-hang / multi-GB growth after the
GC fix (branch `diag/org-mode-perf-hang`, from `main` @ `f0c7e1e8`)

Scope

After the STACK_TOP-after-cold-load-grow GC fix (`1cfb42f4`), `(org-mode)` no
longer crashes, but does not terminate in practical time and grows RSS by
multiple GB, *even with GC fully disabled* via `(nelisp--gc-diag 7)`. This
session root-caused the hang to a single, isolated, reproducible Lisp form
and classified it as a superlinear/impractical real computation, not an
infinite loop and not a GC pathology.

Method

- Built `./target/nelisp` (`make standalone-reader`) on this worktree.
- Rebuilt the org cold-load image via `NELISP_E2E_KEEP=1 scripts/cold-image-org-e2e.sh 1`
  (default, fast prelude — the same one the harness uses by default; 60
  vendor files, 102,432 total lines, replay-load 9.97s, dump 0.74s, cold-boot
  0.84s / 677,732 KB peak RSS, faithfulness conjuncts IDENTICAL between
  replay-loaded and cold-booted process). Image kept at
  `/tmp/cold-image-org-e2e.n1Jc4W/org-run1.img` for this session's probes
  (a tmp path — regenerate with the same command if resuming this work).
- Probed with `./target/nelisp --cold-load-from IMG --no-prompt < formfile`,
  never wrapped in the `timeout` *binary* — that was an early methodology
  trap in this session: `timeout` forks the real reader as a *child* and the
  `timeout` process itself blocks in `sigsuspend()` waiting for
  SIGALRM/SIGCHLD, so `$!` right after `cmd & ` under a `timeout` wrapper is
  `timeout`'s own PID, not the reader's — every RSS sample and gdb backtrace
  taken against that PID describes `timeout` (flat ~1.9 MB RSS, `sigsuspend`
  backtrace), not the reader. Enforcing the deadline in the polling loop
  itself and reading `/proc/<real-nelisp-pid>/status` fixed this; all
  results below are against the real reader PID.

Bisection trail

1. `(org-mode)` alone: RSS climbs from ~6.5 MB to 6.48 GB by t=30 s (killed);
   not naturally terminating.
2. Read `(define-derived-mode org-mode outline-mode ...)` in vendor
   `org/org.el` (read-only, `nelisp-emacs-lib/vendor/emacs-lisp/org/org.el:4927`).
   First heavy call in the body is `(org-load-modules-maybe)`.
3. `(org-load-modules-maybe)` alone: HANG (killed t=20 s, RSS 4.06 GB) —
   reproduces standalone, nothing else from `org-mode`'s body is needed.
4. `org-load-modules-maybe` (`org.el:727`) is `(dolist (ext org-modules)
   (condition-case-unless-debug nil (require ext) (error ...)))` over
   `org-modules` = `(ol-doi ol-w3m ol-bbdb ol-bibtex ol-docview ol-gnus
   ol-info ol-irc ol-mhe ol-rmail ol-eww)` (confirmed via direct probe;
   `org-modules-loaded` is `nil` in this image).
5. Bisected the 11-element list via literal `progn`/`require` chains (one
   process per prefix length, "ONE reader at a time"):
   - First 3 (`ol-doi ol-w3m ol-bbdb`): PASS, 1.02 s.
   - First 4 (adds `ol-bibtex`): PASS, 1.63 s.
   - First 5 (adds `ol-docview`): PASS, 2.24 s.
   - First 6 (adds `ol-gnus`): HANG (killed t=15 s, RSS 2.86 GB) —
     reproduced twice (once alongside a second, unrelated concurrent probe
     that should be disregarded per the "ONE reader at a time" rule; retested
     alone and confirmed).
   - **`(require 'ol-gnus)` alone, first form in a fresh process: HANG.**
     Minimal, fully isolated repro — no `org-mode`, no `dolist`, no
     `condition-case-unless-debug` needed.
   - Confirmed byte-for-byte with GC explicitly disabled first:
     `(progn (nelisp--gc-diag 7) (require 'ol-gnus))` — HANG, killed t=20.1 s,
     RSS 5.45 GB. Matches the task's stated premise (not a GC pathology).

Why `ol-gnus` differs from its 10 `org-modules` siblings

`ol-gnus.el` (`vendor/emacs-lisp/org/ol-gnus.el:35-38`) does
`(require 'gnus-sum) (require 'gnus-util) (require 'nnheader) ...`.
`gnus-sum.el` itself (`vendor/emacs-lisp/gnus/gnus-sum.el:27,61-72`) requires
`gnus`, `gnus-group`, `gnus-spec`, `gnus-range`, `gnus-int`, `gnus-undo`,
`gnus-util`, `gmm-utils`, `mm-decode`, `shr`, `url` (already loaded), `nnoo`.
The vendor mirror actually *contains* the full real Gnus package at
`vendor/emacs-lisp/gnus/`: **106 files, 120,283 lines** — larger than the
entire 60-file/102,432-line org chain this cold image was built from. By
contrast the other 10 `org-modules` either have no real transitive
dependency in this vendor tree (`ol-bbdb.el` requires `org-macs`/`cl-lib`/
`org-compat`/`ol` only — no top-level `(require 'bbdb)`; `bbdb.el` itself
isn't even present in the vendor mirror) or a single small file
(`ol-bibtex.el` → `vendor/emacs-lisp/textmodes/bibtex.el`). `require`'ing
those legitimately succeeds in well under a second each. `(require
'ol-gnus)` is the one sibling whose *real* dependency graph is a
120K-line subsystem, and this reader cannot get through that in practical
time or memory.

Evidence: growth rate

Isolated `(require 'ol-gnus)` run, 1 s samples (`/proc/<pid>/status`
VmRSS), representative window once past the initial ramp-up:

| t (s) | RSS      | Δ/s (KB) |
|-------|----------|----------|
| 6     | 1,054,716| —        |
| 7     | 1,297,104| 242,388  |
| 8     | 1,539,388| 242,284  |
| 9     | 1,779,508| 240,120  |
| 10    | 2,021,644| 242,136  |
| 15    | 3,231,748| ~242,000 (avg over 5-14)|
| 20    | 4,452,568| ~242,000 (avg over 15-19)|
| 25    | 5,661,748| ~242,000 (avg over 20-24)|
| 28    | 6,387,016| ~245,300 (avg over 25-27, killed here) |

Growth is **strikingly linear** (±1% variance) at ~240 MB/s sustained for
the entire 22+ s window probed, both with GC at its default cadence and
with GC explicitly disabled (`nelisp--gc-diag 7`, confirmed same order of
growth, 5.45 GB/20.1 s ≈ 272 MB/s). No inflection/acceleration was observed
in the window we could safely probe (killed at 6 GB per the task's budget).

Evidence: gdb backtraces rule out a zero-progress/wrong-sentinel loop

Samples taken with `gdb -p PID -batch -ex bt` at t=5 s and t=15 s during the
isolated `(require 'ol-gnus)` run:

- t=5 s: 1015 frames. Top of stack:
  `nl_apply_sym_eq_w → nl_apply_name_eq_funcall → nl_apply_name_classify →
  nl_apply_builtin → nl_apply_function → nl_eval_inner_cons → ... →
  nl_sf_while_step → nl_sf_while → ... → nl_sf_dolist → ... → nl_sf_let_star`
  (genuine Lisp-level `while`/`dolist`/`let*` special-form frames — the
  interpreter is executing real loop/binding constructs from the loaded
  Gnus source, not stuck inside a single native primitive).
- t=15 s: 679 frames — a **different, shallower** call chain than t=5 s
  (stack **shrank**, it did not just grow). This directly rules out both
  hypotheses the task asked to discriminate: not a fixed-PC zero-progress
  spin (the top frames and total depth both changed), and not runaway
  unbounded recursion (depth went down, not up, between samples).
- A separate `(org-mode)` full-body run (not just the isolated form) showed
  the same pattern: 748 frames at t=5 s → 752 at t=15 s (near-flat, ±0.5%),
  with the shallow frames showing entirely different dispatch functions at
  each sample (`nl_bf_required`/frame-bind chain at t=5 s vs.
  `nl_apply_sym_eq_w`/`nl_sf_setq`/`nl_sf_if` chain at t=15 s) — again,
  forward motion through many distinct top-level forms, not a stuck loop.
- The very first (methodologically-confounded) attempt to backtrace this
  under a `timeout`-wrapped invocation is preserved above as a documented
  trap: it showed a flat, unchanging `sigsuspend` backtrace at 3 separate
  10-second intervals with RSS pinned at 1.9 MB — that pattern (identical
  PC region, zero RSS movement) is what a *real* zero-progress hang would
  look like, and is exactly what a naive read of those first three
  backtraces could have been mistaken for, before the `timeout`-PID
  confound was found and corrected.

Allocation site (native): one representative t=5 s sample from the full
`(org-mode)` run had, at the top of stack:

```
nl_hdr_set_mark → nl_freelist_take → nl_alloc_bytes → nl_val_clone_into
  → nelisp_frame_bind_prepend → nelisp_frame_bind_in_ht → nelisp_frame_bind
  → nelisp_env_bl_frame → nelisp_env_bind_local → nl_bf_bind_sym → ...
```

Mechanism

`nl_val_clone_into` (`lisp/nelisp-cc-val-load.el:108`) is the shared,
public entry point every non-immediate value bind goes through: binding a
function-call argument or a `let`/`let*` local to any cons/vector/
string/symbol-boxed value allocates a **fresh 32-byte box**
(`alloc-bytes 32 8`, `nl_vci_box` at `lisp/nelisp-cc-val-load.el:98`) and
deep-clones/rc-bumps the source into it (`nl_sexp_clone_into`), every
single time, unconditionally — there is no "already uniquely owned, just
move it" fast path. `nelisp_frame_bind_prepend`/`_in_ht`
(`lisp/nelisp-cc-frame-bind.el:162,224`) call this on every local binding
made while applying a lambda or evaluating `let`/`let*`/`dolist`. The
evaluator also has no macroexpansion cache (each macro call is re-expanded
from its source form every time it is reached), so files that lean heavily
on macros (Gnus makes extremely heavy use of `defcustom`/`defgroup`/
backquote-based helper macros, with large `:type` specs and docstrings)
multiply this per-bind cost across however many such forms exist in the
120K lines being loaded. Since everything a `load` defines this way
(functions, variables, plists, custom metadata) stays genuinely reachable
from the global symbol tables afterward, none of it is garbage — which is
exactly why disabling GC entirely changes nothing (confirmed above): GC was
never the bottleneck, there was never anything to collect.

This is not a novel failure mode for this codebase — it is the same
mechanism already named and worked around elsewhere. See
`scripts/nelisp-standalone-build.el:2767-2770`:

> "Native buffer-scan helpers (Doc 142 Gate 5 OOM fix): an interpreted
> per-char while over a ~500KB buffer string churns ~1MB of arena PER
> ITERATION (value-semantics clones + per-form eval garbage, GC only at
> form boundaries) -> 60GB+ RSS. These do the scan natively instead."

That fix routed four specific hot string-scan loops around the cost with
dedicated native builtins. The `(require 'ol-gnus)` hang is the same
"value-semantics clones + per-form eval garbage" mechanism, but distributed
across the *load-time interpretation of a whole 120K-line package*, not a
single hot loop — there is no single call site to route around.

Classification

**Superlinear / impractically expensive real computation — not an infinite
loop, not a GC pathology.** `(org-mode)`'s default `org-modules` includes
`ol-gnus`; in this vendor tree `require`'ing it is not a no-op or a
file-missing fast-fail (as it would be for a real end user without Gnus
configured) — it genuinely walks `load-path`, finds the real ~120K-line
Gnus package, and interprets it form-by-form at a sustained, essentially
constant ~240 MB/s. Nothing about the growth (linear rate, changing/
shrinking backtrace depth across samples, genuine `while`/`dolist`/`let*`
frames) indicates a wrong-sentinel spin; everything indicates the reader is
plowing forward through a very large amount of real source at a cost per
bind/macro-expansion that is far higher than practical for a package this
size. It would very plausibly complete given enough wall time and RAM
(tens of GB, many minutes+) — which is precisely why "does not terminate
in practical time" is the accurate description, not "hangs forever."

Why no fix is implemented this session

The task's bounded-fix profile (one wrong-primitive sentinel, or one
memoizable helper) does not apply:

- Ruled out wrong-sentinel infinite loop (see backtrace evidence above:
  changing/shrinking depth, changing dispatch functions across samples).
- The allocation is not attributable to one call site: `nl_val_clone_into`/
  `nelisp_frame_bind_*` sit on the path of *every* function call and
  `let`/`let*`/`dolist` binding in the interpreter; narrowing a fix to "this
  one form" is not meaningful.
- A real fix is either (a) a general evaluator-level macroexpansion cache,
  or (b) an ownership/refcount-aware fast path in `nl_val_clone_into` that
  skips the fresh-box allocation when safe. Both are cross-cutting
  evaluator/GC-adjacent architecture changes with real correctness risk
  (cache invalidation on `defmacro`/`fset` redefinition; aliasing safety for
  in-place mutation), well outside a single-session `let*`-only DSL patch,
  and neither is a "swap one sentinel" change.

Remediation proposal (not implemented)

1. **Macroexpansion cache.** Key on the macro call form's own (stable
   within one `load`) address; cache slot holds the expansion pointer plus
   a generation counter bumped whenever the macro's symbol-function is
   redefined (`defmacro`/`fset`). Common-case cost becomes one hash lookup
   (the interpreter already has a bucket-table pattern in
   `nelisp_frame_bind_in_ht` to model this on) before falling into
   `nl_sf_*`/`nl_apply_special` macro dispatch. Expected impact: files that
   invoke the same macro shape hundreds-to-thousands of times (Gnus's
   `defcustom`/`defgroup`/backquote helpers; org's own
   `define-derived-mode`-style macros) move from O(expansions ×
   macro-body-size) to O(expansions) after the first hit per distinct call
   site — likely the largest single lever here, but sized on a hunch, not a
   microbenchmark; would need one before committing engineering time.
2. **Bind-path allocation.** Give `nl_val_clone_into`
   (`lisp/nelisp-cc-val-load.el:108`) a fast path for the case where the
   source slot's refcount is already 1 (uniquely owned, e.g. a freshly
   constructed argument that provably isn't aliased elsewhere) — mutate/move
   in place instead of `alloc-bytes 32 8` + `nl_sexp_clone_into`. This is
   exactly the class of change the repo's own DSL constraints (`let*`-only,
   never `setq` a parameter) exist to make safe; it should be scoped as its
   own investigation with a narrow, dedicated smoke (in the spirit of
   `standalone-reader-derived-mode-shape-smoke`) rather than folded into
   this session.
3. **Bounded, safe, non-reader workaround (not applied here, flagged for
   awareness):** the org e2e/smoke harness could bind `org-modules` to a
   safe subset (or `nil`) before calling `(org-mode)` when the goal is to
   smoke-test core mode setup rather than the optional link-type
   integrations — this sidesteps the impractical Gnus load entirely without
   touching interpreter internals, matching what a real end user without
   Gnus configured would experience (a fast `file-missing` skip via the
   existing `condition-case-unless-debug` in `org-load-modules-maybe`).
   Not applied this session because the task's brief asked for a
   reader/evaluator-level diagnosis, not a harness config change.

Recommended next step

Microbenchmark the macroexpansion-cache proposal against a synthetic file
that repeats one non-trivial macro (e.g. a `defcustom`-shaped macro) a few
thousand times, comparing wall time/RSS with and without a naive
form-address-keyed cache, before investing in the real cache-invalidation
design. Independently, re-run this exact repro
(`(require 'ol-gnus)` on this cold image) after any such cache lands to see
whether it alone is enough to bring the load into practical range, or
whether the bind-path allocation (item 2 above) is also required.

================================================================================

Follow-up investigation (2026-07-04, branch fix/org-element-parse-tree):
org-element-parse-buffer's "(error nil)" defect, and what it unmasks

Context

Merge be5a8304 (eval-time backquote spelling fix) left one item open: after
that fix, `(with-temp-buffer (insert "* h") (org-mode)
(org-element-parse-buffer) t)` no longer raised `(void-function \`)`, but hit
"a distinct defect deeper in org-element parse-tree construction" -- one
probe framing showed `(error nil)`, and isolating
`org-element-org-data-parser` + `org-element--parse-elements` together had
produced a SEGFAULT. This session diagnosed both.

Manifestation (a): the "(error nil)" signal

`(condition-case err (with-temp-buffer (insert "* h") (org-mode)
(org-element-parse-buffer) 'OK) (error (list 'E err)))` prints `(E (error
nil))`. Bisecting the call chain (`org-element-parse-buffer` ->
`org-element-org-data-parser` -> `org-with-wide-buffer`) shows the ACTUAL
defect is shallower and simpler than a signal-stashing bug: `(backquote 42)`
-- typed directly, no reader sugar involved -- evaluates to `nil` instead of
`42`, on this specific cold-loaded org image only. A bare `./target/nelisp
--repl` (no cold-load) evaluates the identical form correctly. So this is a
STATE defect introduced somewhere in the replay/cold-load pipeline for THIS
image, not a bug in the reader's own backquote/quasiquote logic (confirmed:
`nelisp--bq-expand`/`-list`/`-build`, the actual expansion logic `backquote`
delegates to, are plain functions and give the CORRECT expansion for every
shape tested, including interior `,`/`,@`, when called directly or via a
differently-named clone macro with an IDENTICAL body -- only a macro
literally named `backquote` is affected).

Root cause (bisected via a binary search over the replay `.repl` stream,
prefix-by-prefix, checking `(backquote 42)` after each prefix): the
generated replay stream that feeds this worktree's cold-image build (see
`scripts/cold-image-org-e2e.sh`, itself calling nelisp-emacs-lib's
`scripts/vendor-repl-standalone-replay.el`) contains, near the very start of
the chain (in the `nemacs-bootstrap.repl` "src/emacs-backquote.el" chunk,
and twice more while replaying this worktree's own
`scripts/nelisp-stdlib-prelude.el`), a BODY-LESS
`(defmacro backquote (form))`. Verified against host Emacs 30.1:
`(symbol-function 'backquote)` there is `(macro . #[byte-code ...])` -- a
compiled byte-code object, not an interpreted closure with a Lisp-readable
body. Whatever host-side machinery in nelisp-emacs-lib serializes "the body
of this defmacro" for replay cannot recover one from a byte-code object and
silently emits an empty body instead of skipping the (re)definition or
otherwise preserving semantics. A body-less `defmacro` legitimately expands
to `nil` on ANY Lisp implementation, including real Emacs -- this reader's
evaluator is doing exactly the right thing with the (corrupted) input it is
given. Replaying that hollow form clobbers this reader's own correctly-
behaving, natively-prelude-baked `backquote` (and its real-Emacs-style
`` \` `` alias) with a permanent always-nil stand-in for the remainder of the
chain, which is why every macro that expands via backquote/`,@` syntax
loaded AFTER that point -- notably org-macs.el's `org-with-wide-buffer` and
`org-no-read-only`, both load-bearing for `org-element-org-data-parser` --
silently breaks (their bodies are never executed; e.g. `(with-temp-buffer
(org-no-read-only (insert "Z")) (buffer-string))` returns `""`, not `"Z"`).
`org-element-org-data-parser` wraps its entire body in
`org-with-wide-buffer`, so it always returns `nil`, and `org-element-parse-
buffer` propagates that into an eventual `(error nil)` deeper in
`org-element--parse-elements`'s consumption of the (wrongly-nil) org-data
node.

Classification: NOT a reader/evaluator/GC-core defect in this repo. It is a
`.repl`-replay-generation defect in nelisp-emacs-lib (out of scope to touch
per this task's brief). Confirmed bounded, low-risk workaround applied
entirely within this repo (`scripts/cold-image-org-e2e.sh`): re-assert
`(defmacro backquote (form) (nelisp--bq-expand form))` and the `` \` ``
alias once, right after the vendor/bootstrap replay chain and before this
worktree's own arena dump -- `nelisp--bq-expand` itself is never named
"backquote" so it survives the clobber untouched and is already loaded and
correct at that point. Verified on a freshly regenerated image: `(backquote
42)` -> `42`, `(backquote (a (comma-at (list 1 2)) b))` -> `(a 1 2 b)`,
`(with-temp-buffer (org-no-read-only (insert "Z")) (buffer-string))` ->
`"Z"`. `scripts/cold-image-org-e2e.sh`'s own faithfulness/timing gate is
unaffected (still `RESULT: IDENTICAL`, same ~10.6s replay / ~0.9s cold-boot
shape as before the patch).

Manifestation (b): the SEGFAULT, and what fixing (a) actually unmasks

With backquote/,@ genuinely working (the workaround applied), `org-with-
wide-buffer` and `org-no-read-only` now execute their real bodies instead of
silently no-op'ing to nil -- and this exposes that `org-mode`'s (and
`org-element-org-data-parser`'s) REAL initialization, once actually allowed
to run instead of being silently skipped, does not complete in practical
time on this interpreter: `(with-temp-buffer (insert "* h") (org-mode) t)`
alone (no org-element-parse-buffer at all) does not return within 20 s and
RSS grows past 900 MB in the first 5 s; `org-element-org-data-parser` alone
was interrupted (SIGINT) under gdb at ~4.7 GB RSS / 16 s CPU with backtraces
taken 6 s apart showing genuinely DIFFERENT call chains each time (once deep
in `nl_push_captured_walk` closure-capture recursion, once inside a
`while`/`setq` loop body) -- i.e. forward progress through real,
increasingly expensive work, not a stuck infinite loop or a fixed-PC spin.
The full task probe, `(with-temp-buffer (insert "* h") (org-mode)
(org-element-parse-buffer) t)`, against the freshly-regenerated (backquote-
fixed) cold image: killed by `timeout 90` at 91 s wall, zero output, zero
error -- consistent with "would very plausibly complete given much more
wall time and RAM," not a crash.

This is the SAME mechanism already root-caused for `(require 'ol-gnus)`
earlier in this file: no macroexpansion cache (every macro call is re-
expanded from source every time it is reached) plus `nl_val_clone_into`
paying a fresh 32-byte-box allocation + deep clone for every non-immediate
`let`/`let*`/lambda-argument bind, unconditionally. `org.el`/`org-element.el`
lean at least as heavily on macros (`org-with-wide-buffer`,
`org-with-limited-levels`, `defcustom`/`defgroup`-shaped forms building
keyword/outline regexps, etc.) as Gnus does, so the same superlinear cost
applies here too -- it was simply MASKED until now by the (a) defect above
silently skipping most of that work rather than paying for it. This also
retroactively explains a previously-logged, only-partially-understood
observation in `docs/design/156-flat-arena-boot-install.org` ("the reader
spends >170 s inside org.el alone" under one prelude/bootstrap pairing,
"...does not [install org-mode]" under another): both symptoms are
consistent with `org-mode`'s bring-up being genuinely, independently
expensive on this interpreter whenever its backquote-heavy setup code is
allowed to actually execute, not a separate, additional defect.

The originally-reported SEGFAULT for the combined
`org-element-org-data-parser` + `org-element--parse-elements` probe was not
independently reproduced this session (time/resource-bounded; every run in
this class was killed by `timeout`/SIGINT well before any crash, always
mid-progress, never at a stable PC) -- it is plausible under this same
"real, unboundedly expensive computation, eventually resource-starved"
mechanism that a longer, unbounded run previously ran the custom arena
allocator (`nl_chunk_try_alloc`, seen live on the stack in both gdb
snapshots this session) out of growable memory and THAT failure path
segfaults rather than signalling a Lisp error; this was not chased further
this session (would require deliberately running to OOM under gdb, which
risks the shared machine -- CLAUDE.md already caps this class of
investigation at "kill >6GB RSS").

Classification: superlinear/impractically-expensive real computation (same
class as the already-documented Gnus finding above), NOT GC, NOT a new
reader-primitive defect, NOT a new spelling/macro-machinery gap. Evaluator-
core surgery (macroexpansion cache and/or a `nl_val_clone_into` fast path,
both already proposed above) would be required to make `org-mode`/
`org-element-parse-buffer` complete in practical time -- out of scope for
this session's bounded-fix brief. STOPPING here per that scope; the
existing remediation proposal above (macroexpansion cache, then bind-path
allocation fast path) applies unchanged and is now motivated by two
independent call sites (Gnus, org-mode) rather than one.

Net effect of this session: `org-with-wide-buffer`/`org-no-read-only`/any
other backquote-splice-based macro are now CORRECT again on this cold image
(previously silently wrong), and the true remaining blocker for the
project's actual target probe is now cleanly isolated to the single,
already-diagnosed evaluator-cost issue above -- rather than a mix of "wrong
answer" and "unknown crash."
---

2026-07-04 third follow-on: `.nelc` artifact-reader scale-dependent hang —
same root mechanism, new trigger (branch `fix/nelc-reader-scale-hang`)

Scope

Investigated a separately-reported symptom: `eval-elisp-artifact FILE.nelc
FORM` on the standalone reader hangs/never-returns-in-practical-time for a
2.04 MB real-world `.nelc` (compiled from four `newDTW-nelisp` game-runtime
`.el` files: `game-runner.el` + `gamedata-simple.el` +
`gamedata-conditional.el` + `sumi-json.el`), while a 533 B one-defun
`spike.nelc` loads instantly. Built the standalone reader fresh in this
worktree (`nelisp-standalone-build-reader`, target `windows-x86_64`) and ran
all reproduction/measurement under `timeout`, copying the exe to
`nelisp-R.exe` per the parallel-worktree convention so as not to touch the
other concurrent agent's `nelisp.exe` runs.

Measurement curve (all `eval-elisp-artifact FILE.nelc '(princ "OK")'`, same
binary, single-run wall-clock; system was also running another agent's
concurrent, memory-heavy `emacs.exe` processes, so absolute seconds carry
noise, but the qualitative shape is consistent across three independent
probe families):

- Real corpus, full 2.04 MB (267 top-level forms): did not return in 180 s+
  (matches the reported measured fact).
- Real corpus, first 37 top-level forms only (`game-runner.el` +
  `gamedata-simple.el`, 57 KB — no `gamedata-conditional.el` data at all):
  did not return in 240 s. This immediately falsified "it's about total file
  size" — 57 KB of *this* content is already impractical.
- Isolated synthetic probe, a single bare top-level `(quote (N-elements))`
  literal with a small nested shape per element (mirrors the real corpus's
  `("index-ref" (("index-ref" ...)) ...)` IR pattern): N=10 → 2 s, N=25 → 6 s,
  N=50 → 12 s, N=100 → 50 s, N=200 → did not return in 90 s. A flat
  same-length list of plain integers (`(quote (0 1 2 ... 399))`, N=400) loads
  in 3 s — so raw element count is not the driver; nested/bound sub-structure
  is.
- Isolated synthetic probe, N sequential simple `(puthash "key-i" i tbl)`
  top-level forms (no nesting at all): N=300 → 29 s, N=600 → did not return
  in 150 s. So a large *count of top-level forms/binds*, independent of any
  single form's nesting, reproduces the same wall.
- Compiling any of the above (`compile-elisp-artifact`, which is host-Emacs-
  backed per the `fix/artifact-host-helper` work merged at `d04c43d3`) is
  fast regardless of size (1-2 s even for the 200/600-element cases) — the
  cost is exclusively in the standalone runtime's own load-time replay/eval,
  never in the `.el` → `.nelc` compiler.

Hypotheses tested and ruled out

1. **GC thrash.** Toggled the mid-form safepoint / collection gate at
   runtime via the existing `(nelisp--gc-diag 7/8)` diagnostic builtin
   (`scripts/nelisp-standalone-build.el:3059-3095`) around the identical
   N=100 nested-literal probe on one unmodified binary: 23 s (collect
   default-enabled) vs 22 s (`(nelisp--gc-diag 7)` collect force-disabled)
   — no measurable difference. (An earlier same-session attempt to test this
   by flipping the Windows dynamic-arena `collect ENABLED` literal at
   `scripts/nelisp-standalone-build.el:1191` and rebuilding showed an
   apparent ~2x speedup, but that comparison used two different binaries
   built at different times while another agent's competing multi-GB
   `emacs.exe` processes were active on the same machine; the clean, same-
   binary, runtime-toggled `nelisp--gc-diag` comparison above supersedes it
   and is trusted. That source edit was reverted before committing —
   `git diff` against `scripts/nelisp-standalone-build.el` on this branch is
   empty.) Conclusion: GC is not the driver here, consistent with the
   `(require 'ol-gnus)` finding above ("GC was never the bottleneck, there
   was never anything to collect").
2. **Argument/quote-literal deep-copy per call.** Read
   `lisp/nelisp-cc-sexp-clone-into.el`: cloning a `Cons` (tag 7) value is a
   plain refcount bump (`nelisp_nlconsbox_clone`) + 32-byte slot copy, not a
   recursive deep copy — O(1) regardless of list length. Ruled out as the
   asymptotic driver (it does still fire on every bind, see below, just not
   with a cost that scales with the cloned list's length).
3. **Elisp-hosted hash-table exhaustive-fallback-scan bug (real, but a red
   herring for *this* target).** `lisp/nelisp-stdlib-hash.el`'s `puthash`/
   `gethash` do have a genuine O(current table size) "correctness fallback"
   that scans every bucket on any miss in the key's own bucket (intended
   only for `cons`-shaped keys per its own comment, but applied
   unconditionally to every key type) — confirmed by an isolated 302-`puthash`
   repro taking ~8 s. A fix (gate the fallback on `(consp key)`, since only
   cons keys can have an unstable hash — atom keys are always stable) was
   written and correctness-tested (atom-keyed table still overwrites/reads
   correctly; cons-keyed table still uses the safe fallback and reads back
   correctly) but then **reverted, unapplied**: the standalone reader does
   not call this file's `puthash`/`gethash` at all — `puthash`/`gethash`/
   `make-hash-table` are native builtins (`scripts/nelisp-standalone-build.el:2648`,
   dispatch table around line 9717, implementation `wf_ht_put`/`wf_ht_get`/
   `wf_ht_find_table` at lines 4429-4539). That native implementation
   *already* has the correct optimization: `wf_ht_key_hash_stable_p`
   (line 4402) gates the exhaustive fallback scan (`wf_ht_find_vec_from`) to
   only unstable (deeply-nested/tag-7) keys, exactly the fix this session
   would have made — atom keys (the common case, including every string key
   in the real corpus's `gr-event-names`/`gr-funcs` tables) are already O(1).
   Confirmed empirically: the isolated 302-entry `dolist`/`puthash` repro
   measured the identical ~8 s both before and after the (later-reverted)
   `lisp/nelisp-stdlib-hash.el` edit, on the same rebuilt binary. Branch is
   clean of this change (`git diff --stat` empty) — noted here only because
   `lisp/nelisp-stdlib-hash.el` may still be live for some other
   (non-standalone-native) NeLisp configuration, where the same one-line
   `(consp key)` gate would be a legitimate, low-risk parity fix if anyone
   ever measures that path as hot.

Root cause (same mechanism as the `(require 'ol-gnus)` finding above, new
trigger)

Both surviving, non-falsified probe families — many-form-count and single-
nested-literal — bottom out in the same place already diagnosed earlier in
this file: **`nl_val_clone_into` (`lisp/nelisp-cc-val-load.el:108`)
unconditionally allocates a fresh 32-byte box (`alloc-bytes 32 8`) and deep-
clones/refcount-bumps into it for every non-immediate value bind — every
function-call argument, every `let`/`let*` local, every `setq` inside a
`dolist`/`while` body — with no "value is already uniquely owned, just move
it" fast path, called via `nelisp_frame_bind_prepend`/`_in_ht`
(`lisp/nelisp-cc-frame-bind.el:162,224`) on every bind the interpreter
performs.** (Verified this citation is still accurate on this branch's HEAD,
not stale from the prior investigation.) Combined with the interpreter
having no macroexpansion cache (`dolist`, used pervasively by exactly this
kind of generated data-registration code, like every other macro, is
reduced to primitives once per occurrence but every *iteration*'s `setq`/
bind still pays the full unconditional-clone cost), this makes the standalone
reader's per-bind cost high enough that:

- A single top-level form holding a ~100-200 element nested data literal
  (the `gr-defun "funcNNN" '(...)"` / bare-quote shape that `newDTW-nelisp`'s
  generated `.el` files use pervasively for game-state IR) already costs
  tens of seconds, because reading it recurses through `nelisp--rd-one`
  once per sub-list/atom and now *evaluating* the resulting quoted structure
  and the enclosing call also binds through the same unconditional-clone
  path.
- A `.nelc` module with hundreds of independent top-level forms (defuns
  installed one by one, or bare calls like `gr-defun`/`puthash`) pays this
  same high constant-factor cost once per form/bind, and a real corpus like
  the 2.04 MB one under investigation here has both dimensions at once (267
  top-level forms, several of which carry nested IR literals with hundreds
  of elements) — compounding into the reported 180 s+ non-termination.

This is consistent with the earlier classification for `(require
'ol-gnus)`: **superlinear-looking from the outside because of a very large,
constant per-bind cost multiplied across a large amount of genuine, reachable
work — not an infinite loop, and not (per the ruled-out hypotheses above)
primarily a GC pathology.** The apparent quadratic-ish curve shape in the
N=50→100→200 bare-quote probe above is most parsimoniously explained as the
same "sustained, high-constant-cost linear work" the `ol-gnus` investigation
already measured directly (steady ~240 MB/s interpretation rate there), not
as a distinct, newly-introduced O(n²) algorithm specific to the `.nelc`
loader — this session did not have time to run the same rigorous multi-
sample/backtrace-depth-tracking methodology that investigation used to
confirm "linear, not wrong-sentinel-spin, not GC" as cleanly as it did there;
that would be the highest-value next step before concluding the growth
exponent precisely.

Why no fix is implemented this session

Same reasons as the `(require 'ol-gnus)` entry above, which this finding
corroborates rather than supersedes: the cost sits on `nl_val_clone_into`/
`nelisp_frame_bind_*`, the path *every* bind in the interpreter takes; there
is no single call site specific to `.nelc` loading to route around, and the
two real fixes on the table (a macroexpansion cache; an ownership/refcount-
aware fast path in `nl_val_clone_into` that skips the fresh-box allocation
when the source is provably uniquely owned) are both cross-cutting
evaluator/GC-adjacent changes with real correctness risk (cache invalidation
on redefinition; aliasing safety for in-place mutation) — outside a single
session's `let*`-only DSL patch budget, exactly as already concluded above.

POSIX-untouched statement

No POSIX/Linux/macOS build path files were touched. All edits (subsequently
reverted) were confined to the Windows dynamic-arena GC-enable literal in
`scripts/nelisp-standalone-build.el` (diagnostic only, reverted) and
`lisp/nelisp-stdlib-hash.el` (reverted, unapplied). `git diff` against
`main` on this branch is empty; no runtime source changes are being
proposed or shipped from this session.

Regression battery run against the rebuilt (unmodified-source) standalone
reader before closing out

- `spike.nelc` (one-defun `.el`, `(defun spike-answer () 42)`) round-trips:
  `eval-elisp-artifact spike.nelc '(spike-answer)'` → `42`, exit 0.
- `getenv` at top level and inside `let`: both return the process
  environment value correctly via `eval-elisp-source`.
- `(error "boom")` → exit code 1 with an `nelisp: uncaught error: ...` stderr
  line (pre-existing message detail — prints the error symbol and a nil
  payload rather than echoing "boom" verbatim — unrelated to this
  investigation and unchanged by it).
- `call-process` (top-level, `let`-scoped, and `:file` destination): all
  three currently fail with `void-function: (string-match-p)` inside the
  standalone `call-process`/`executable-find` polyfill
  (`scripts/nelisp-stdlib-prelude.el` around line 3641) — a pre-existing gap
  unrelated to hash tables/GC/binding (confirmed by inspection: the call
  site has no connection to any file touched this session); flagging for
  whoever owns that command surface, out of scope here.
- `eval-elisp-source` works (exercised throughout the above).
- Two consecutive `nelisp-standalone-build-reader` rebuilds from the
  identical (reverted-to-`main`) source produced byte-identical
  `target/nelisp.exe` (`sha256sum` match) — build determinism holds.

No runtime-code commits accompany this entry; this is a diagnosis-only
session per the task's "if the culprit is the open upstream defect itself,
park it" guidance, applied here to the sibling defect (unconditional
per-bind clone cost + absent macroexpansion cache) rather than the GC
mark/sweep corruption defect the earlier entries in this file track.

---

2026-07-05 `org-element-parse-buffer` sampling-profile scoping session
(branch `diag/parse-buffer-profile`, investigation-only, no runtime edits;
run against worktree `nelisp.wt-coldgrow` @ `7ce7b13a`, reusing the kept
cold image `/tmp/cold-image-org-e2e.10laLp/org-run1.img` and probe
`/tmp/parse-probe.el` from the same-day cold-heap-growth work)

Scope

Task: profile where `(with-temp-buffer (insert "* h") (org-mode)
(org-element-parse-buffer))` spends its time on this cold (org.el +
org-element.el pre-loaded) image, which does not terminate within 300 s
(rc=124) while consuming real CPU. Method: gdb sampling (`bt`) every 3-10 s
over two runs, then micro-decomposition timing of smaller pieces, then
source reading to explain the dominant frames. No source files changed;
only this file.

Sampling results (2 runs, 9 backtraces total, `gdb -p PID -batch -ex 'bt
15..20'`, RSS-based 6 GB kill-switch tripped both times before a fixed
sample-count budget was exhausted)

RSS growth was extreme and monotonic, not a stall: run 2 alone measured
673 MB (t=3s) -> 1.44 GB (6s) -> 2.55 GB (9s) -> 3.65 GB (12s) -> 4.76 GB
(15s) -> 5.87 GB (18s) -> 6.98 GB (21s, killed) -- a sustained ~330-360
MB/s allocation rate. This is real, large, genuine work, consistent with
the earlier entries in this file, not a spin/sentinel bug.

The 9 backtraces cluster into two closure-lifecycle families plus the
already-documented generic eval/bind-path frames:

- **Closure *application* side** (3/9 samples: run1 s1, run2 s1, run2 s5):
  `nelisp_frame_bind` <- `nl_pc_bind_one` <- `nl_push_captured_walk`
  (self-recursive, one stack frame per captured `(NAME . CELL)` pair, 12-19+
  deep in a `bt 15-20` window that did not reach the base case) <-
  `nl_env_push_captured`. This walks a closure's entire captured alist and
  re-binds every entry into a fresh frame on every *call* of that closure
  (`lisp/nelisp-cc-evalport-env-leaves-frame.el:144-174`).
- **Closure *creation* side** (2/9 samples: run1 s2 via `nl_sf_cond_walk`
  chains ending in alloc; run2 s2 via `nl_capture_walk_buckets` x8+ <-
  `nl_capture_walk_frame`): walks *every bucket* of the captured frame's
  `fast-hash-table`, explicitly regardless of population --
  `lisp/nelisp-cc-frame-stack-find.el:274-296` ("Iterate the bucket array
  slots j = 0..bc-1 ... `sexp-payload-ptr` on `Sexp::Nil` yields 0 ... which
  the inner bucket walker handles" -- i.e. empty buckets are cheap to
  reject but are still visited one recursive call each), then repeats this
  for *every enclosing frame* from the current depth down to 0
  (`nl_capture_walk_frames`, same file lines 316-335). The public entry is
  `nelisp-lexframe-stack-capture-to-depth` (`lisp/nelisp-lexframe.el:254`,
  wired through `nl_capture_descend_native` /
  `lisp/nelisp-cc-frame-stack-find.el:337-365`), invoked once per `(lambda
  ...)` literal evaluated, with `max-depth` = the *current* active-frame
  stack depth at that point -- i.e. every closure created anywhere in a
  deep call chain re-walks the *entire* lexical scope chain currently in
  effect, not just the frames that hold its actual free variables.
- Remaining 4/9 samples are the already-documented generic path: `nl_let_*`
  / `nl_val_clone_into` / `nl_sexp_clone_into` / `nl_apply_lambda_inner` /
  `nl_apply_function` chains (per-bind fresh-box clone, same mechanism as
  the `nl_val_clone_into` finding earlier in this file,
  `lisp/nelisp-cc-val-load.el:108`).

Micro-decomposition (single-line probes, `time`, cold-image unless noted
"vanilla" = bare `./target/nelisp --eval`, no cold-load)

| probe | condition | N | wall | per-call (less ~0.6s cold-boot/~0.03s vanilla floor) |
|---|---|---|---|---|
| `(let ((x 1)) x)` in a `while` | vanilla | 100000 | 1.636s | ~16.4 us |
| `(let ((x 1)) x)` in a `while` | cold image | 1000/5000 | 0.641/0.712s | ~17.8 us (delta) |
| `(funcall (lambda () 1))` | vanilla | 10000 | 0.189s | ~15.9 us |
| `(let ((y 5)) (funcall (lambda () y)))` (capturing) | vanilla | 10000 | 0.265s | ~20 us |
| named trivial `(defun my-triv-fn () 1)` call | cold image | 100 | 0.623s | negligible (~= boot floor) |
| named trivial defun call | vanilla | 10000 | 0.128s | ~10-13 us |
| `(string-match "^\*+ " "* h")` in a `while` | vanilla | 10000 | 18.694s | **~1869 us** |
| `(string-match "\*+" "* h")` in a `while` | cold image | 100 | 2.264s | **~16.6 ms (delta)** |
| `with-temp-buffer` alone (no insert/goto-char/looking-at) | cold image | 10/50/100 | 0.630/0.653/0.706s | ~0.8 ms |
| `with-temp-buffer` + `(insert "* h")` | cold image | 100 | 0.974s | ~2.7 ms (delta over temp-buffer-alone) |
| `with-temp-buffer` + insert + `(goto-char 1)` | cold image | 100 | 1.142s | ~1.7 ms (delta over insert-alone) |
| `with-temp-buffer` + insert + `(looking-at "\*+")` | cold image | 100 | 2.773s | **~18 ms (delta over insert-alone)** |
| `with-temp-buffer` + insert + goto-char + looking-at (task's probe (d)) | cold image | 10/50/100 | 0.890/1.794/2.953s | ~23 ms/iter, linear in N (no acceleration) |
| full task probe (org-mode + org-element-parse-buffer) | cold image | 1 | timeout (300s / 60s both) | n/a -- non-terminating in budget |

The dominant cost, with evidence

**Regex matching (`string-match`/`looking-at`) has an enormous per-call
baseline cost even in isolation, and both `string-match` on a bare string
and `looking-at` on a buffer show an additional ~10x regression once
running inside the org-loaded cold image, while plain binds, plain
closures, and plain named-function calls show *no* such regression
between vanilla and cold image.** This rules out "any bind" and "any
function call" as the org-specific driver (both measured within noise of
each other, ~16-20 us, in both conditions) and narrows the org-specific 10x
to something reached specifically from inside the search/regex call chain.

`string-match`/`looking-at` are pure-Elisp (not native) --
`nelisp-emacs-lib/packages/nelisp-emacs-buffer-core/lisp/emacs-buffer-builtins.el:87,248`
delegate to `nelisp-emacs-lib/src/nelisp-regex.el`'s hand-written NFA
engine (`nelisp-rx-compile` / `nelisp-rx--scan` / `nelisp-rx--match-from`,
lines 657-877), which already has a compile-result cache
(`nelisp-rx--compile-cache`, line 896, keyed by pattern string) precisely
*because* "org-element matches the same handful of regexps thousands of
times" per its own comment. A fresh cold boot's cache has only 2 entries
before the probe runs (checked directly:
`(hash-table-count nelisp-rx--compile-cache)` => `2`), and per-iteration
cost in the `looking-at`/`string-match` loops above was flat/linear across
N=10/50/100 (not "slow first call, fast rest"), so a bloated compile-cache
from org.el's own *loading* is not the direct driver of the loop-level
measurements here (loading mostly just `defun`s/`defvar`s org.el's forms
without executing them). Two source-confirmed, independently real defects
remain the leading candidates for *why calling into org.el/org-element.el's
own function/closure machinery is expensive*, and best explain both the
10x regex-path regression above and the full parse's multi-minute/multi-GB
blowup:

1. **Capture-on-creation walks the entire active frame stack, all buckets,
   regardless of population** (`nl_capture_walk_buckets` /
   `_frame` / `_frames`, `lisp/nelisp-cc-frame-stack-find.el:274-335`,
   entered via `nelisp-lexframe-stack-capture-to-depth`,
   `lisp/nelisp-lexframe.el:254`, `max-depth` = current call depth). This is
   an O(depth x total-buckets-across-all-enclosing-frames) cost paid on
   *every* `(lambda ...)` literal evaluated anywhere in a deep call chain,
   not gated by the lambda's actual free variables. org.el/org-element.el
   are large `lexical-binding: t` files with hundreds of top-level
   forms/functions; a recursive-descent parser (org-element's own
   architecture) both recurses deeply (growing `max-depth`) and evaluates
   closures pervasively (`dolist`/`mapcar`/`cl-case`/`pcase` bodies,
   `save-excursion`-adjacent helper closures inside the buffer-core
   compat shim, etc.), so this cost compounds with parse depth -- a
   plausible root cause for a superlinear-*looking* wall-clock curve
   without a literal O(n^2) algorithm anywhere.
2. **Hash tables never rehash/grow their bucket vector as entries
   accumulate** (`wf_ht_put`, `scripts/nelisp-standalone-build.el:4790-4833`
   -- every insert path, vector-backed or not, only ever *prepends* to
   whatever bucket/chain already exists; no code path resizes the bucket
   vector or reorganizes the flat pre-bucketing cons chain). Any
   long-lived table that accumulates many entries (a large closure's
   captured-variable table, or `nelisp-rx--compile-cache` after a real
   parse run, or org.el's own module-level symbol tables if similarly
   represented) degrades from O(1) toward O(chain length) per lookup/put,
   permanently, with no self-healing.

What was *not* isolated in the ~30-minute budget (flag for next session,
before attempting a fix)

The exact call site inside the `looking-at`/`string-match` chain that
creates the closure(s) the profiler caught mid-capture-walk was not pinned
down to a specific line -- `nelisp-ec-looking-at`
(`nelisp-emacs-lib/packages/nelisp-emacs-buffer-core/lisp/nelisp-emacs-compat.el:1027-1038`)
itself has no literal `(lambda` in its body, so the walk is most likely
reached one or more frames deeper (inside `nelisp-rx--scan`/
`nelisp-rx--match-from`'s own control flow, or inside a macro-expanded
`dolist`/`cl-case` in a caller), or is in fact **not regex-specific at
all** -- calling *any* function defined deep inside org.el/org-element.el
(as opposed to a function freshly `defun`'d at the top of a throwaway
probe script, which is what the "named trivial defun call" row above
actually measured) may be equally expensive if defect #1 is the real
driver, since a function's own closure over its *defining file's*
accumulated module scope would be captured once and then re-walked on
every subsequent lambda creation nested under it. The single highest-value
next experiment is: call a small **non-regex** helper already defined deep
inside org.el (e.g. `org-back-to-heading-or-point-min` or similar) 100x on
this same cold image and compare against the "named trivial defun" and
"looking-at" rows above -- if it is also ~ms-per-call, defect #1 (capture
walk cost scales with *which module defined the callee*, not with regex)
is confirmed as the primary driver and the fix should target
`nl_capture_walk_buckets`/`nelisp-lexframe-stack-capture-to-depth` (replace
whole-stack, whole-bucket capture with static free-variable-set capture,
computed once per lambda source location and cached the same way the
existing macroexpansion cache is, per the design already flagged in this
file's `nl_val_clone_into` finding); if it is cheap, the regex engine
itself (`nelisp-rx--scan`/`match-from`) is the correct target instead.

Recommended fix, ranked by expected leverage (for whoever implements next)

1. **First**: run the one experiment above to disambiguate "closure-capture
   cost scales with enclosing module size" (fix target:
   `lisp/nelisp-cc-frame-stack-find.el:274-335` +
   `lisp/nelisp-lexframe.el:254`) vs. "the NFA regex engine itself is slow"
   (fix target: `nelisp-emacs-lib/src/nelisp-regex.el:732-877`). Both are
   real, source-confirmed inefficiencies regardless of which one turns out
   to dominate `org-element-parse-buffer` specifically.
2. If capture cost dominates: change `nl_capture_walk_frame`
   (`lisp/nelisp-cc-frame-stack-find.el:298-314`) to skip the full
   bucket-array scan for frames whose live-entry count
   (`ht-record.slots[2]`, already tracked per that function's own comment
   at lines 306-308 but currently *unused* by the walk) is 0, and to walk
   only as many buckets as there are live entries once a cheap
   free-variable filter is available -- or, for a bigger win with the same
   risk profile as the already-proposed `nl_val_clone_into` fast path,
   compute the lambda body's free-variable set once per distinct lambda
   *source position* (cacheable the same way `nelisp-rx--compile-cache` and
   the existing macroexpansion cache already are) and capture only those
   bindings instead of the whole reachable frame stack.
3. Independently of #2, fix `wf_ht_put`
   (`scripts/nelisp-standalone-build.el:4790-4833`) to rehash/grow the
   bucket vector past a load-factor threshold -- currently a correctness-
   neutral but performance-unbounded gap that will keep re-manifesting
   (regex compile-cache, closure captured-var tables, anything else
   hash-table-backed that grows large over a long-lived run) even after
   #2 lands.
4. Out of scope for a quick fix, noted for completeness: the 4/9 generic-
   path samples reconfirm the pre-existing `nl_val_clone_into`
   unconditional-fresh-box-per-bind cost
   (`lisp/nelisp-cc-val-load.el:108`) already tracked elsewhere in this
   file; no new evidence here changes that finding's status.

No source files were modified in this session; only this FINDINGS.md
entry. Probe artifacts reused from the same-day cold-heap-growth session
(`/tmp/parse-probe.el`,
`/tmp/cold-image-org-e2e.10laLp/org-run1.img`) plus this session's own
scratch probes under `/tmp/test-*.el` (not committed, scratch only).

---

## Post-all-fixes re-probe of `org-element-parse-buffer`: it no longer hangs -- it crashes with a corrupted frame-stack argument (exit 88)

Ran at `perf/closure-capture-narrowing` @ `5d8bd34b` (closure-capture
narrowing, macroexpansion cache, `wf_ht` rehash/growth, and the cold-heap
chunk-cursor fix are all merged into this history). Binary
`./target/nelisp` was already built matching this HEAD (no source file
newer than the binary). Re-ran the exact task probe from the prior
FINDINGS entry above --

```
(with-temp-buffer (insert "* h") (org-mode)
  (prin1 (if (org-element-parse-buffer) 'PARSE-OK 'PARSE-NIL)))
```

-- against the freshest matching cold image
(`/tmp/cold-image-org-e2e.A0Gb1u/org-run1.img`, dumped by this same
binary at 01:12, one commit before HEAD; verified compatible: `(featurep
'org)` / `(fboundp 'org-element-parse-buffer)` both `t` on this image
under this binary).

**Headline result: this is no longer a >300s hang. It is now a
sub-second crash.** `timeout 15 ./target/nelisp --cold-load-from
.../org-run1.img --no-prompt < /tmp/parse-probe.el` exits with code 88
almost immediately, with *no* stdout at all (not even a partial print).
`strace -f -e trace=mmap,exit` on the same invocation shows the process
issuing a handful of legitimate chunk-growth `mmap`s (64 MiB / 256 MiB
range, consistent with normal arena/chunk growth) and then one final:

```
mmap(NULL, 1125899906908160, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = -1 ENOMEM
exit(88)
```

1125899906908160 bytes is ~1 PiB (`0x4000000010000` = 2^50 + the 64 KiB
chunk-alignment pad). `exit(88)` is this runtime's own designated
out-of-memory panic exit (`nl_os_alloc_fail`, `scripts/nelisp-standalone-
build.el:1282` on this Linux x86_64 path: `(syscall-direct 60 88 0 0 0 0
0)` = `exit_group(88)`), not a signal/segfault -- the runtime detected
the failed allocation and exited cleanly on purpose.

### gdb: the exact call chain and the corrupted argument

Breakpoints on `nl_chunk_alloc_new`, `nl_os_alloc_fail`, and
`nelisp_frame_stack_ensure_capacity` (all present as ELF symbols in the
release binary -- `nm target/nelisp` resolves 1462 of them) against the
same cold-load + `parse-probe.el` invocation give a full, symbol-named
native backtrace at the point of the fatal allocation:

```
nl_chunk_alloc_new
  <- nl_alloc_bytes
  <- nl_alloc_vector
  <- nelisp_frame_stack_ensure_capacity_grow
  <- nelisp_frame_stack_ensure_capacity
  <- nelisp_frame_push
  <- nl_push_and_bind
  <- nl_ali_push_frame
  <- nl_apply_lambda_inner
  <- nl_apply_closure_or_lambda
  <- nl_apply_function
  <- nl_eval_inner_cons
  <- nl_ei_cons_tail / nl_ei_cons_dispatch
  <- nl_eval_inner
  <- nelisp_eval_call
  <- nl_driver_eval_published
  <- bf_load_eval_loop
  <- bf_load
  <- nelisp_apply_function
```

i.e. the crash is in ordinary function-call machinery (applying a
lambda pushes a new lexical frame, which must first ensure the
frame-stack backing vector is big enough), not in regex, not in
org-element's own logic, and not in `wf_ht` (hash-table) growth.

Directly inspecting registers at the `nelisp_frame_stack_ensure_capacity`
breakpoint (`(frames-ptr needed scratch-slot)` = `rdi rsi rdx` on this
SysV target, `lisp/nelisp-cc-frame-ensure-capacity.el:118`) on the hit
that leads to the crash:

```
frames_ptr (rdi) = 0x7fffa288ce38
needed     (rsi) = 140735301062233   (~1.4e14)
scratch    (rdx) = 0x7fff7da097e8
```

`frames_ptr` is a **native-C-stack address** (`0x7fff...` range) -- every
legitimate arena/heap allocation observed in this same run lands in the
`0x7ff3...`/`0x7ff9...` mmap range instead. Per
`lisp/nelisp-cc-frame-push.el:96,178-183`, `frames-ptr` must be a
persistent `Env::frames_record` living in the arena, and `needed` is
computed as `(+ (sexp-int-unwrap (record-slot-ref-ptr frames-ptr 1)) 1)`
-- i.e. a small depth counter read off of that same record. Here `needed
- frames_ptr == 33`, i.e. `needed` is almost exactly `frames_ptr`'s own
address plus a small constant, not a plausible depth+1 value. A
"legitimate" explanation (the interpreter really did push ~1.4x10^14
frames) is physically impossible in the sub-second wall time actually
elapsed (this would require ~10^14 frame pushes/sec). This is therefore a
**corrupted-argument bug**: some caller in this chain is handing
`nelisp_frame_stack_ensure_capacity`/`nelisp_frame_push` a stack-resident
garbage value in place of the real arena `frames-ptr`, and the resulting
garbage "depth" propagates through
`nelisp_frame_stack_ensure_capacity_compute_cap`'s power-of-two doubling
(`lisp/nelisp-cc-frame-ensure-capacity.el:60-68`) to `new-cap = 2^47`,
which `nelisp_frame_stack_ensure_capacity_grow` then asks `vector-make`
to allocate (2^47 slots x 8 bytes = 2^50 bytes) -- the mmap that fails.

### What was ruled out

- **Not `wf_ht` rehash/growth** (the 7355c5e7/e9b42390 fix). Three
  targeted micro-repros, each a plain `(make-hash-table)` grown then
  round-tripped through the identical `nelisp--arena-dump-image-stream`
  -> `--cold-load-from` path this task's harness uses, then grown
  further *after* cold-load:
  - 20 entries, no growth involved: count reads back correctly (20 ->
    21) after cold-load, no corruption.
  - 5000 entries (growth already triggered live, pre-dump, at the
    2048->4096-bucket boundary): count reads back correctly (5000 ->
    5001) after cold-load.
  - 4095 entries pre-dump (just under the 4096 growth threshold), then
    2 more puthashes *after* cold-load specifically crossing the growth
    boundary for the first time post-restore: count reads back
    correctly (4095 -> 4097), grows cleanly, no corruption, no extra
    chunk mmap even needed.
  All three: exit 0, correct counts, no huge mmap. `wf_ht_meta_count` /
  `wf_ht_maybe_grow` are exonerated as the origin of this specific crash.
- **Not the closure-capture-narrowing commit's own new allocations.**
  5d8bd34b's new runtime code
  (`nl_env_capture_lexical_with_filter`/`nl_clx_symbol_filter_walk`,
  `scripts/nelisp-standalone-build.el:14010-14070`) only ever calls
  `alloc-bytes 32 8` (fixed-size 32-byte scratch slots) or builds a small
  cons-list filter -- it has no size-scaled `vector-make` call anywhere,
  so it cannot be the direct source of a 2^47-element vector allocation.
  It remains the leading suspect for *clobbering an adjacent call's
  register/stack-slot* (see below), since the corruption is new/newly-
  reachable specifically after this commit landed (its own commit
  message reports "parse-buffer target timeout 300s -> timeout 300s" as
  of 01:15; the crash reported here reproduces reliably against the
  matching binary/image less than an hour later with no source changes
  in between -- i.e. this session's own re-run is what surfaced the
  crash, not a code change since that commit).
- **Not literally a >300s hang any more** for this exact probe/image --
  confirmed 5+ repeated runs, all exit 88 in well under a second.

### Attempted minimal repro outside org.el (inconclusive in budget)

`--eval` (vanilla boot, no cold image) of a recursive closure-creating
function:

```elisp
(defun deep-rec (n)
  (if (<= n 0) 0
    (let ((clo (lambda () n)))
      (+ (funcall clo) (deep-rec (1- n))))))
(prin1 (deep-rec N))
```

- N=3000: completes correctly (`4501500`), <1s, no corruption.
- N=50000: does **not** crash/corrupt -- it times out (>20s, the *old*
  slow-hang symptom, not the new corrupted-argument crash).

So plain "create one capturing closure per recursion level, N deep" does
not by itself reproduce the corrupted-`frames-ptr` crash at either depth
tried -- the real org-element call graph has some additional ingredient
(pervasive macro-expanded closures, non-tail helper recursion inside
org-element.el/org-macs.el, and/or `nelisp_frame_stack_ensure_capacity
_copy`'s own native recursion cost scaling with current depth,
`lisp/nelisp-cc-frame-ensure-capacity.el:69-90`, being non-tail and thus
itself consuming native stack proportional to live frame count on every
single grow event) that this synthetic repro didn't hit within the N
values tried in this session's time budget.

### Recommended fix, ranked (for whoever/whatever implements next)

1. **First**: bisect a minimal non-org repro between N=3000 (clean) and
   N=50000 (slow-hang, not crash) from the synthetic `deep-rec' probe
   above -- ideally add nested/non-tail helper calls per level (not just
   one closure) to better mirror org-element's own call shape -- so the
   corrupted-`frames-ptr` crash can be hit in under a second instead of
   only via the multi-minute org cold-image pipeline. This is the
   single highest-leverage next step; everything else is much slower to
   iterate on without it.
2. Audit the AOT-generated calling convention for the call chain
   `nl_ali_push_frame` -> `nl_push_and_bind` -> `nelisp_frame_push` ->
   (`extern-call`) `nelisp_frame_stack_ensure_capacity`
   (`lisp/nelisp-cc-frame-push.el:178-183`), specifically cross-
   referenced against the 5d8bd34b diff to
   `nl_env_capture_lexical_with_filter` (widened its internal `invec`
   from 3 to 5 slots, `scripts/nelisp-standalone-build.el` around line
   14041-14060) and its two new callers `nl_env_capture_lexical` /
   `nl_env_capture_lexical_filtered`. The corrupted `frames-ptr` reads as
   a stack slot rather than the real arena Record pointer, which is the
   signature of a caller-saved register or stack slot getting clobbered
   by a widened call signature emitted earlier in the same native frame
   (i.e. lambda-creation immediately preceding the next `frame_push` for
   applying it) -- check whether the AOT compiler's register/stack-slot
   allocation for calls into the newly 5-slot `invec` path correctly
   preserves whatever slot the *subsequent* `nelisp_frame_push` still
   expects to hold `frames-ptr`.
3. Independently of #2: `nelisp_frame_stack_ensure_capacity_copy` and
   `_compute_cap` (`lisp/nelisp-cc-frame-ensure-capacity.el:60-90`) are
   non-tail-recursive elisp helpers whose own native recursion depth is
   O(live frame count) / O(log(needed/cap)) respectively -- every single
   grow event burns additional native call-stack frames proportional to
   how many live interpreter frames are being copied, stacking on top of
   the ~11-native-frames-per-Elisp-level cost already visible in the
   backtrace above. This is a plausible contributor to the N=50000
   synthetic repro's hang-instead-of-crash and to native stack pressure
   generally; converting these two to real iteration (if/when the AOT
   DSL gains mutable locals) removes one axis of native-stack
   consumption independent of whichever call site turns out to own the
   register-clobber from #2.
4. Do **not** re-open "regex is slow" or "closure-capture walks every
   bucket" as explanations for the current blocker -- both are prior,
   now-separately-fixed/mitigated findings in this file about a
   *different* bottleneck. The mechanism documented here is new (or was
   previously masked by the old bottleneck timing out before the
   interpreter ever recursed deep enough to hit it) and is a distinct
   defect in the frame-stack/call machinery, not the regex engine or the
   `wf_ht` hash-table implementation.

No source files were modified in this session; only this FINDINGS.md
entry (branch `diag/parse-buffer-focus`). Reused the prior session's
`/tmp/parse-probe.el`. New scratch artifacts from this session (not
committed): `/tmp/mini-ht-repl.txt`, `/tmp/mini-ht-cold-repl.txt`,
`/tmp/mini-ht-grow-repl.txt`, `/tmp/mini-ht-grow-cold-repl.txt`,
`/tmp/mini-ht-boundary-repl.txt`, `/tmp/mini-ht-boundary-cold-repl.txt`,
`/tmp/deep-closure-repro.el`, `/tmp/deep-closure-repro2.el`,
`/tmp/gdb-chunk-trace.gdb`, `/tmp/gdb-depth-trace.gdb` (gdb batch
scripts used for the backtraces/register dumps above), and the cold
image reused from the pre-existing e2e run at
`/tmp/cold-image-org-e2e.A0Gb1u/org-run1.img`.

## 2026-07-05 re-profile session: the >300s parse-buffer probe does NOT run at all on this HEAD -- it still crashes (exit 87), inside `(org-mode)` itself, before `org-element-parse-buffer` is ever reached

Investigation-only, branch `profwork` (clone `nelisp.clone-capture`, tracking
`origin/main`), HEAD `f36e6e82` ("Merge fix/frames-ptr-corruption: exit-88
crash eliminated, loud guard added"). Task handed down asserted this probe
was, on the current binary, "a genuine >300s CPU-bound computation" needing
a real cost profile (gdb sampling, RSS growth, loop-vs-advance). **That
premise does not hold on this exact HEAD/build: the probe crashes
deterministically in well under a second, via the guard `93b011bc` itself
added, and it crashes before `org-element-parse-buffer` runs at all.** This
finding -- not a performance profile -- is this session's headline result.

### Reproduction

Built `./target/nelisp` fresh from this HEAD (`make standalone-reader`,
binary timestamped after both `93b011bc` and the `f36e6e82` merge commit --
not a stale pre-fix binary). Generated a fresh cold image with this exact
binary via `NELISP_E2E_KEEP=1 timeout 300 bash scripts/cold-image-org-e2e.sh
1` (default env, no overrides -- matching this file's own established
methodology): replay-load 6.28s, dump 0.56s, cold-boot 0.52s/513,808 KB
peak RSS, faithfulness conjuncts `(t t t t (interactive) t)` IDENTICAL
between replay-loaded and cold-booted process. Image kept at
`/tmp/cold-image-org-e2e.f2U2Hz/org-run1.img`.

Reused the existing task probe verbatim (`/tmp/parse-probe.el` from a
prior session):

```elisp
(with-temp-buffer (insert "* h") (org-mode)
  (prin1 (if (org-element-parse-buffer) 'PARSE-OK 'PARSE-NIL)))
(prin1 'probe-end)
```

`timeout 10 ./target/nelisp --cold-load-from .../org-run1.img --no-prompt <
/tmp/parse-probe.el` -- **3/3 repeated runs, exit code 87, zero stdout,
stderr `nelisp: frame-stack corrupt needed > 2^32`, in well under a
second each time.** This is the loud guard `93b011bc` added at
`lisp/nelisp-cc-frame-ensure-capacity.el:185-186` /
`nelisp_frame_stack_ensure_capacity_bad_needed` (`:163-168`, writes the
message and `exit_group(87)`), not a hang and not the old exit-88
PiB-mmap crash -- but it is still a crash, and it fires on a completely
fresh cold image built from this exact HEAD.

**Isolation: the crash is entirely inside `(org-mode)`, never reaches
`org-element-parse-buffer`.** A second probe with `org-element-parse-buffer`
removed --

```elisp
(with-temp-buffer (insert "* h") (org-mode) (prin1 'ORG-MODE-OK))
(prin1 'probe-end)
```

-- crashes identically: exit 87, same stderr message, same wall time (well
under a second). gdb (`break nelisp_frame_stack_ensure_capacity`, print
`$rdi`/`$rsi`/`$rdx` on every hit, `bt` when `$rsi > 4294967296`) confirms
the two probes hit the **bit-identical** bad call --
`frames-ptr=0x7fffa28d2ce0 needed=140735301062233 (0x7fff7da08e59)
scratch=0x7fff7da097e8` -- after the *same* number of preceding legitimate
`nelisp_frame_stack_ensure_capacity` calls (2163, all with small correct
`needed` values climbing normally, e.g. `...14 15 140735301062233`
immediately before the bad one) regardless of whether
`org-element-parse-buffer` is present in the script at all. The backtrace
at the bad call:

```
nelisp_frame_stack_ensure_capacity <- nelisp_frame_push <- nl_push_and_bind
  <- nl_ali_push_frame <- nl_apply_lambda_inner <- nl_apply_closure_or_lambda
  <- nl_apply_function <- nl_eval_inner_cons <- nl_ei_cons_tail
  <- nl_ei_cons_dispatch <- nl_eval_inner <- nelisp_eval_call
  <- nl_driver_eval_published <- bf_load_eval_loop <- bf_load
  <- nelisp_apply_function <- nl_apply_builtin <- nl_apply_function
  <- nl_eval_inner_cons <- ... <- nl_sf_progn_body_step <- nl_sf_progn_get_cdr
```

-- the identical call-chain shape `93b011bc`'s own commit documented fixing
(`nl_apply_lambda_inner -> nl_ali_push_frame -> nl_push_and_bind ->
nelisp_frame_push -> nelisp_frame_stack_ensure_capacity`). This is a
**sibling instance of the same defect class**, not a new bug family: this
time it is the `needed` argument (2nd arg, `rsi`) that goes bad while
`frames-ptr` (`rdi`) stays the same, correct-looking value across all 2163+
calls in the run (`0x7fffa28d2ce0`, constant); previously (`11346ea0`
entry) it was `frames-ptr` itself that went bad while `needed` looked
plausible. `93b011bc`'s commit message says it "pre-localize[d]
frames-ptr/depth/needed [in `nelisp_frame_push`] so extern-call argument
evaluation does not re-read them" -- i.e. it already specifically targeted
`needed` as a clobber-risk local, and this session's reproduction shows
that mitigation is incomplete.

### Likely exact site: `nelisp_frame_push`'s own `needed` local, `lisp/nelisp-cc-frame-push.el:143-184`

```elisp
(let* ((fp frames-ptr)
       (depth (sexp-int-unwrap (record-slot-ref-ptr fp 1)))
       (needed (+ depth 1))                    ; computed here, line 145
       (ht-slot (alloc-bytes 32 8))
       (buckets-slot (alloc-bytes 32 8))
       (frame-slot (alloc-bytes 32 8))
       (int-slot (alloc-bytes 32 8)))
  (and
   (record-make ... 3 ht-slot)                 ; 7 intervening calls
   (vector-make 16 buckets-slot)               ; (record-make / vector-make /
   (record-slot-set ht-slot 1 buckets-slot)    ;  record-slot-set x3 /
   (sexp-int-make int-slot 16)                 ;  sexp-int-make x2)
   (record-slot-set ht-slot 0 int-slot)
   (sexp-int-make int-slot 0)
   (record-slot-set ht-slot 2 int-slot)
   (record-make ... 1 frame-slot)
   (record-slot-set frame-slot 0 ht-slot)
   (extern-call nelisp_frame_stack_ensure_capacity
                fp needed (vector-ref-ptr scratch-vec-ptr 2))  ; used here, line 183
   ...))
```

`needed` is computed once, early, from a fully legitimate small `depth`
value, then must survive across 7 intervening AOT-compiled calls (4 of
them freshly-added `alloc-bytes 32 8` scratch buffers on the same call's
native stack) before its only use. The corrupted value observed,
`0x7fff7da08e59`, sits in the *same page* as this run's most recent
`alloc-bytes`-derived scratch/`scratch-slot` pointers (e.g.
`0x7fff7da07bd8`, `0x7fff7da08ec8`, `0x7fff7da097e8` -- all within the same
~2.4 KB region) -- i.e. `needed`'s storage (register or stack slot) is
most plausibly being overwritten by one of `ht-slot`/`buckets-slot`/
`frame-slot`/`int-slot`'s own `alloc-bytes` result or by a call that
reuses whatever slot the AOT allocator assigned to `needed`. This is the
single most concrete, narrowly-scoped lead produced by this session:
audit the AOT compiler's register/stack-slot allocation for
`nelisp_frame_push` specifically across the 4 `alloc-bytes 32 8` +
`record-make`/`vector-make`/`record-slot-set` sequence between `needed`'s
binding and its use at the `extern-call` -- `93b011bc`'s "pre-localize"
fix evidently did not give `needed` a slot/register that survives this
particular sequence of intervening calls.

### Regex engine location (asked for, previously unresolved) -- definitively answered

`string-match`/`string-match-p`/`match-beginning`/`match-end`/
`match-string`/`split-string`/`replace-regexp-in-string` are **interpreted
prelude Elisp**, not DSL-native/AOT-compiled and not sourced from the
sibling `nelisp-emacs-lib` repo. They are thin aliases
(`scripts/nelisp-standalone-build.el:10332-10347`,
`nelisp-standalone--reader-repl-prelude-source`) over a from-scratch
backtracking regex matcher, `lisp/nelisp-stdlib-regexp.el` (364 lines,
"Doc 143": `nlre--parse`/`nlre--parse-alt`/`nlre--parse-seq`/
`nlre--parse-atom`/`nlre--parse-set` build an AST; `nlre--match-list`/
`nlre--match-atom1`/`nlre--match-star` do the actual backtracking match;
entry point `nlre-string-match`, line 287). This file is concatenated
into the reader's REPL prelude text and evaluated by the ordinary
interpreter at boot (`nelisp-standalone--reader-repl-prelude-forms`,
`:10350-10360`) -- it is genuinely interpreted, dynamically-scoped
(`-*- lexical-binding: nil -*-` per its own header), plain Elisp, not
compiled to native code by the `nelisp-cc-*` pipeline. Landed in commits
`7a69693c`/`c8677e73` ("Doc 143"), superseding (in this repo) an older
regex engine an earlier FINDINGS entry (the `7ce7b13a`-era gdb-sampling
session, above) described living in the *sibling* repo
(`nelisp-emacs-lib/src/nelisp-regex.el`, a hand-written NFA with a
`nelisp-rx--compile-cache`) -- that description is now **stale for this
worktree**: `nelisp-rx`/`nelisp-emacs-lib` do not appear anywhere in this
repo's actual matching code path any more; `nelisp-emacs-lib` is used
*only* for host-side `.repl` generation (`cold-image-org-e2e.sh`'s phase
(a), read-only), never for the runtime string-match implementation baked
into `./target/nelisp`.

**Cache status: there is no compiled-pattern cache at all.**
`nlre-string-match` (`lisp/nelisp-stdlib-regexp.el:287-305`) calls
`(nlre--parse regexp)` -- a fresh recursive-descent parse allocating a new
AST -- on **every single call**, unconditionally, before any matching is
attempted. There is no `defvar`/hash-table anywhere in this file keyed on
pattern text, no memoization of `nlre--parse`'s result, nothing analogous
to the sibling repo's now-superseded `nelisp-rx--compile-cache`. Every
`string-match`/`looking-at`/`re-search-forward` call pays a full O(pattern
length) parse cost from scratch, independent of how many times that exact
pattern string was already seen -- a large fixed per-call overhead for
org.el's own giant precompiled regexps (`org-element-paragraph-separate`
and friends, built via `regexp-opt`-style alternation and potentially
thousands of characters), on top of the O(buffer length x backtracking)
match cost proper. This is a real, source-confirmed inefficiency
independent of the crash above, and matches this session's task
description's suspicion exactly ("is a compiled-pattern cache present").

### Micro-timing (this HEAD's binary; org.el loaded but `(org-mode)` never
called, to stay clear of the crash above)

| probe | condition | N | wall | delta vs. empty-loop baseline (same N) | per-call |
|---|---|---|---|---|---|
| `(let ((i 0)) (while (< i 1000) (setq i (1+ i))))` | vanilla `--repl` | 1000 | 0.046s | -- (baseline) | -- |
| `(let ((i 0)) (while (< i 1000) (string-match "\*+" "* h") (setq i (1+ i))))` | vanilla `--repl` | 1000 | 1.287s | +1.241s | **~1.24 ms/call** |
| single `(prin1 (string-match "\*+" "* h"))` | vanilla `--repl` | 1 | -- | -- | prints `00` correctly -- sanity OK |
| empty-loop baseline | cold org image, no `(org-mode)` call | 10000 | 0.563s | -- | -- |
| `string-match` loop, same pattern | cold org image, no `(org-mode)` call | 10000 | 0.501s | **not measurable -- see anomaly below** | n/a |

Vanilla-boot per-call cost (~1.24 ms for a trivial 2-char pattern against a
2-char string, no cache -- consistent with this file's prior ~1.87 ms/call
vanilla measurement, same order of magnitude) is confirmed genuine: the
`while` loop's own auto-printed return value (this runtime prints a
top-level form's final value after evaluating it) correctly showed `1000`
for the baseline, confirming real completion, not a truncated loop.

**New anomaly found this session, NOT chased to root cause (flag for next
session): on the cold-loaded org image specifically (not vanilla), calling
`string-match` -- even exactly once, e.g. bare
`(prin1 (string-match "\*+" "* h"))` as the only top-level form -- produces
*zero* stdout for that form, silently, while the reader continues normally
and the *next* top-level form (e.g. a subsequent `(prin1 'done)`) prints
fine.** Verified at N=1 (single bare call), N=3 (loop with a `prin1` on
every iteration -- none of the 3 print), and N=1000/5000/10000/50000
(loop wall time stays flat at ~0.49-0.51s regardless of N, i.e. *not*
scaling with N the way the baseline empty loop does, e.g. baseline
0.563s@10000 -> 0.871s@50000 while the string-match version stays
~0.50s@10000 and ~0.51s@50000) -- both facts together indicate the loop
body is not actually completing anywhere near N real iterations of
`string-match` on this image, and/or its output is being suppressed, via
some cold-load-specific state (the reader's own "quit flag" /
epoch-boundary check at a fixed arena offset,
`nelisp-standalone--reader-repl-eval-suffix`'s
`(ptr-read-u64 (+ (car (nelisp--arena-stats)) 8) 0)` gate and/or
`nl_boundary_maybe_reclaim`'s epoch check, `scripts/nelisp-standalone-
build.el` -- both consulted around chunk/form boundaries -- are the
leading suspects, unverified). This makes **any** cold-image loop-based
wall-clock string-match timing (including this file's own prior "~16.6
ms/call org image" figure from the earlier gdb-sampling entry above,
which used the same loop-timing methodology without verifying the loop's
own return value) suspect until this is root-caused: a suppressed/short-
circuited loop and a genuinely-fast loop are wall-clock-indistinguishable
without checking the loop's actual completion value, which this session's
probes did check (and found inconsistent with real completion) but the
prior session's probes, as documented, did not.

### What could not be done, and why

The task's Method steps 1 (gdb sampling of the parse loop, 12+ samples
over ~2 min), 3 (loop-vs-advance verdict via buffer-position progress
between samples), and the `org-element--current-element` direct-call
probe are all **inapplicable**: there is no multi-minute (or even
multi-second) `org-element-parse-buffer` execution to sample. The call
never begins -- `(org-mode)` itself crashes first, deterministically, in
well under a second, every time, on this exact binary/image. RSS growth
during the (nonexistent) parse could not be measured for the same reason.

### Recommended fix, ranked

1. **First**: audit `nelisp_frame_push`'s AOT codegen
   (`lisp/nelisp-cc-frame-push.el:143-184`) for why the `needed` local
   (bound line 145, used only at the `extern-call` on line 183) does not
   survive the 4 `alloc-bytes 32 8` + `record-make`/`vector-make`/
   `record-slot-set` x3/`sexp-int-make` x2 calls in between -- despite
   `93b011bc` already claiming to "pre-localize" exactly this variable.
   The corrupted value's proximity to this same `let*`'s own
   `alloc-bytes`-derived scratch addresses is a strong, specific lead:
   check whether the AOT compiler is reusing `needed`'s assigned
   register/stack slot for one of `ht-slot`/`buckets-slot`/`frame-slot`/
   `int-slot`, or failing to reload `needed` from its spill slot before
   the final `extern-call`.
2. Do **not** re-run this exact probe again expecting a >300s CPU-bound
   result until (1) is fixed and independently re-verified (e.g. a bare
   `(org-mode)`-only smoke test exiting 0, not 87) -- this session's
   reproduction was 3/3 deterministic on a freshly-built binary from
   current HEAD, so this is not a flake.
3. Separately, root-cause the cold-image-only `string-match`
   output/loop-completion anomaly above before trusting any future
   cold-image wall-clock timing of regex-calling code (including
   re-validating this file's own prior "~16.6 ms/call" org-image figure).
4. Independent of both crashes: `nlre-string-match`
   (`lisp/nelisp-stdlib-regexp.el:287-305`) has no compiled-pattern
   cache and re-parses every regexp from scratch on every call -- adding
   one (keyed on pattern string, analogous to the already-existing
   macroexpansion cache) is a real, source-confirmed, independent
   optimization opportunity for whenever `org-element-parse-buffer`
   becomes reachable again.

No source files were modified in this session; only this FINDINGS.md
entry (branch `profwork`). New scratch artifacts (not committed):
`/tmp/parse-sanity*.{out,err}`, `/tmp/gdb-parse-probe2.{gdb,out}`,
`/tmp/orgmode-only-probe.el`, `/tmp/gdb-orgmode-only.{gdb,out}`,
`/tmp/regex-len-probe.el`, `/tmp/sm-*.el`, `/tmp/baseline-*.el`,
`/tmp/t1.el`..`/tmp/t5.el`, `/tmp/sm-single*.el`, `/tmp/sm-n3.el`, and the
cold image `/tmp/cold-image-org-e2e.f2U2Hz/org-run1.img` (freshly built
this session from this exact HEAD; regenerate with
`NELISP_E2E_KEEP=1 timeout 300 bash scripts/cold-image-org-e2e.sh 1` if
resuming).

## 2026-07-05 fix follow-up: frame-push `needed` corruption is eliminated by call-adjacent recomputation

Implementation branch attempt: requested branch creation could not be
performed in this sandbox because `.git/index.lock` creation failed with a
read-only filesystem error.  Work was done on the existing checkout, base
HEAD `56a0f382` (`docs(FINDINGS): re-profile invalidated -- parse-buffer
probe still crashes (exit 87), never reaches org-element-parse-buffer`).

### Mechanism confirmed

The latest `profwork` finding was correct: `93b011bc` pre-localized
`frames-ptr`/`depth`/`needed`, but `nelisp_frame_push` still computed
`needed` before four `alloc-bytes` calls and the subsequent
`record-make`/`vector-make`/`record-slot-set`/`sexp-int-make` call chain.
Fresh rebuilds could assign that local to storage later reused/clobbered by
the same frame-push sequence.  The bad value then reached
`nelisp_frame_stack_ensure_capacity` as `needed > 2^32`, tripping the loud
exit-87 guard before `(org-mode)` completed.

### Fix applied

Chosen approach: **A, recompute just before use**, not BSS stash.

`lisp/nelisp-cc-frame-push.el` now wraps the source in a `seq` and adds
three small helpers:

- `nelisp_frame_push_ensure_now`: re-reads `frames-ptr.slot1` and computes
  `depth+1` immediately at the capacity call site.
- `nelisp_frame_push_install_now`: re-reads backing/depth at the vector
  install point instead of trusting the old early `depth` local.
- `nelisp_frame_push_bump_now`: re-reads current depth after install and
  materializes the depth bump from that fresh read.

The main `nelisp_frame_push` no longer binds early `fp`, `depth`, or
`needed`.  `frames-ptr` itself is passed through as the parameter; all
derived frame-stack values are now call-adjacent to their use.  This keeps
the patch local to the failing function and avoids extending the ordinary
BSS layout/linker contract just for this bounded fix.

### Systemic AOT hazard

The AOT compiler's stated contract is that intervals live across a call are
marked `crosses-call` and forced to spill (`src/nelisp-cc.el` linear-scan
comments/implementation).  This incident shows a practical hole in that
contract for DSL locals in long `let*` / `and` sequences: a value can still
behave as if caller-saved or stack-slot storage was reused across intervening
calls.

One more same-shape site was found:
`scripts/nelisp-standalone-build.el`'s
`nl_env_capture_lexical_with_filter` binds `depth` from
`frames_ptr.slot1`, then runs `vector-make` and several `vector-slot-set`
calls before using that old `depth` in `sexp-int-make depth_slot depth`.
That has the same "local computed, calls intervene, local used later as a
call argument" shape.  It is not patched here because the bounded
`nelisp_frame_push` fix removes the active crash, while the compiler-level
local preservation bug needs its own audit/lint pass.  A useful lint is:
flag DSL `let*` locals whose first use as an argument to `extern-call` or a
native helper occurs after any intervening call-form, unless the value is
recomputed or re-read in a helper at the call point.

### Verification

Fresh build #1:

- `timeout 900 make standalone-reader`: PASS.
- `NELISP_E2E_KEEP=1 timeout 300 bash scripts/cold-image-org-e2e.sh 1`:
  PASS faithful; image `/tmp/cold-image-org-e2e.KdwoDy/org-run1.img`.
- `(org-mode)` probe against that fresh image: 3/3 PASS, rc=0, no exit
  87/88; walls 4.065s, 4.070s, 4.065s; output contained `OMDONE`.
- `org-element-parse-buffer` probe against the same image: no crash, timed
  out honestly at `timeout 300` (`rc=124`, wall 5m02s).

Fresh rebuild #2:

- `timeout 300 make standalone-eval-clean` then `timeout 900 make
  standalone-reader`: PASS, cache removed and binary relinked.
- `NELISP_E2E_KEEP=1 timeout 300 bash scripts/cold-image-org-e2e.sh 1`:
  PASS faithful; image `/tmp/cold-image-org-e2e.nN5am7/org-run1.img`.
- `(org-mode)` probe against that second fresh image: PASS, rc=0, wall
  4.077s, no exit 87/88; output contained `OMDONE`.

Regression:

- `standalone-reader-test`: PASS.
- Reader smokes: load/fmt/prelude-equal-reload/nested-backquote-macro/
  derived-mode-shape/ffi/process/realrt/repl/prelude PASS; TLS smoke SKIP
  due no egress to `1.1.1.1:443`.
- `standalone-chunk-growth-test`: PASS.
- GCR: `/tmp/gcr1.el` 10/10 PASS (`out=1`), `/tmp/gcr2.el` 10/10 PASS
  (`out=3`).
- REPL tolerance: undefined function followed by `(+ 40 3)` continued and
  printed `43`, rc=0.
- Capture probes all rc=0: nested `42`, loop-var `(2 1 0)`, shared-var `2`,
  setq-visibility `41`, macro-ref `42`, unused-exclusion `42` (REPL echoes
  duplicate values when `prin1` is used, e.g. `4242`).
