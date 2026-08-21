# `compile-elisp-artifact` silently does nothing (open)

Status: **open, isolated but not identified.**  Introduced by `b7ab399a7`
("Take the differential from 146 disagreements to zero"), which is mine.  The
sibling regression from the same commit -- generated `#s(hash-table ...)`
literals -- is fixed in `2ebfb2a01`; this one is not.

Everything below was measured.  The point of the file is the EXCLUSION LIST:
several plausible causes are already ruled out, and re-testing them is wasted
work.

## Symptom

    $ nelisp compile-elisp-artifact                       # no arguments
      at 2bce30617:  rc=1  "compile-elisp-artifact requires --kind, --input, and --output"
      at HEAD:       rc=0  no output at all

    $ nelisp compile-elisp-artifact --kind nelc --input src.el --output out.nelc
      at 2bce30617:  rc=0, writes out.nelc and out.nelc.manifest.el
      at HEAD:       rc=0, writes nothing

`inspect-elisp-artifact` is the same shape: 2bce30617 answers rc=2 with usage,
HEAD answers rc=0 with nothing.  No error is signalled, no diagnostic printed.

`make standalone-reader-test` fails here, at `command smoke:
compile-elisp-artifact exit=0`.  A full run at 2bce30617 passes every smoke
(`PRE_EXIT=0`), which is what establishes this as a regression rather than an
old defect.

## Where it is NOT

- **Not the artifact runtime cache.**  Cross-swapping the cache file between a
  HEAD build and a 2bce30617 build:

        HEAD binary    + 2bce30617 cache -> fails  (0 files)
        2bce30617 binary + HEAD cache    -> works  (2 files)

  The cache is fine; the binary is not.

- **Not the host-helper path.**  No `/tmp/nelisp-host-helper*.log` is produced,
  so `nelisp-artifact--standalone-host-helper-mode` returns nil on Linux and
  the native path runs.  `getenv` is fbound and works, so the
  `NELISP_DISABLE_HOST_HELPER=1` control was meaningful, and it changes nothing.

- **Not the prelude half of the commit.**  Reverting
  `scripts/nelisp-stdlib-prelude.el` to 2bce30617 while keeping everything else
  at HEAD still fails.

- **Not the float-parsing change.**  Reverting
  `lisp/nelisp-cc-evalport-str-to-float.el` likewise still fails.

- **Not hash tables.**  This was the leading hypothesis, since the same commit
  changed the representation to `(MARKER . ALIST)`.  `make-hash-table`,
  `puthash`, `gethash` (with and without a default), `maphash`, `remhash`,
  `hash-table-count`, `hash-table-test`, `hash-table-p`, `copy-hash-table` and
  `clrhash` all answer identically on both runtimes.

- **Not the printing or error machinery.**  `audit-elisp-artifacts` reaches the
  same code path through the same cache and correctly answers rc=1 with
  `nelisp: audit-elisp-artifacts: no .el sources or .neln artifacts found`, so
  `error`, `condition-case` and `nelisp-artifact--print-error` all work.

- **Not `plist-get` / `plist-member` / `intern` / `string=` on nil /
  `error-message-string` / `expand-file-name` / `file-exists-p`.**  All compared
  directly on both runtimes; all identical.

## Where it is

`scripts/nelisp-standalone-build.el`, in the 373-line half of `b7ab399a7`.
That is the only runtime-affecting file left after the exclusions above (the
commit's other files are tests, baselines and tools).

The failure lands inside `nelisp-artifact-compile-file`
(`lisp/nelisp-artifact.el`, untouched by me): it returns without writing and
without signalling, so `compile-elisp-artifact`'s `condition-case` sees success
and answers 0.

## Two dispatchers, and a trap for the next session

There are TWO generated dispatchers:

- `nelisp-standalone--artifact-command-dispatch-src` (a `cond`, calls the
  functions directly)
- `nelisp-standalone--artifact-command-cache-dispatch-src` (a nested `if`,
  calls through `nelisp--apply`)

Neither is baked into the binary -- `strings target/nelisp | grep -c
compile-elisp-artifact` is **0**, while the same grep over
`target/nelisp-artifact-runtime.el.nelc` is 2.  Instrumenting either dispatch
source and rebuilding therefore prints NOTHING, which looks like "the command
never dispatches" and is misleading.  I lost two build cycles to it.  Instrument
the cache, or the functions in `lisp/nelisp-artifact.el`, instead.

## Next step

Bisect the `scripts/nelisp-standalone-build.el` diff of `b7ab399a7` by feature
block -- the hash-table marker change, the new signallers, the new predicates,
the `wf_any_float` rewrite, the fixed `fset`, the `string-match` rewrites --
reverting one block at a time on top of HEAD.  Roughly a two-minute build per
round, three or four rounds.

    git diff 2bce30617 b7ab399a7 -- scripts/nelisp-standalone-build.el

## Why it went unnoticed

`standalone-reader-test` was not in the gate list I was running when
`b7ab399a7` landed.  That gap is fixed (892fcaf39 widened
`nelisp-validate`'s list to match `tools/ai/nelisp-ai.sh check`), but the gate
is still red for this reason, so a green `nelisp-ai.sh check` is not available
as a signal until this is closed.
