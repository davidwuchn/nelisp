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
