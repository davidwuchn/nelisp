# Working in this repository

Read this file, then `target/ai/STATUS.md`.  Everything else here is
reference material to reach for on demand, not to read up front: some
160 design documents, a 260 KB findings file, a 1300-line Makefile and
several thousand ERT cases do not fit in one session, and skimming them
is how a session ends up confidently wrong.  STATUS has the exact
counts; this paragraph deliberately does not.

## Orient

```sh
tools/ai/nelisp-ai.sh doctor     # toolchain, branch, and which binary is in target/
tools/ai/nelisp-ai.sh status     # regenerate target/ai/STATUS.{json,md}, then read it
```

`STATUS` is generated, per machine, and untracked.  Do not hand-edit it,
and do not accept a claim about this tree that is not in it or in a gate
report.  A hand-written "1549 tests, 0 failures" in a sibling repository
stood unchallenged for months while the suite, once it could actually
run, reported 2859 tests and 127 unexpected results.

## Inner loop

```sh
tools/ai/nelisp-ai.sh check                              # before every commit
tools/ai/nelisp-ai.sh test-one test/nelisp-FOO-test.el   # seconds
tools/ai/nelisp-ai.sh compile                            # byte-compile, error-on-warn
tools/ai/nelisp-ai.sh ns FILE...                         # namespace boundaries (nl-ns)
tools/ai/nelisp-ai.sh gate NAME -- make TARGET            # wrap an existing check
tools/ai/nelisp-ai.sh test                               # full ERT suite
tools/ai/nelisp-ai.sh verify                             # the verdict
```

`check` runs as one step of the CI Linux lane
(`.github/workflows/ci.yml`, "AI toolchain check-tier gates") and then
verifies, so "what will CI say" about that tier is answerable before
pushing rather than after.  The same Linux lane separately runs the
binary-tier gates this file's inner loop lists as their own commands
(`native-artifact`, `perf`, `smokes`, `extras`, plus `standalone-
reader-test`/`emacs-parity`/`binary-size-ratchet` individually rather
than through `standalone`, to avoid running `emacs-parity` twice), the
ERT suite (both JIT settings), and several checks `nelisp-ai.sh` does
not model at all (`bench-aot-tco`, `macho-acceptance-test`) -- none of
which `check` itself covers.  `check` deliberately does not run the
full ERT suite; `verify` holds you to the last `ert-full` report and
prints its age, so run `test` when that column says the evidence is
stale.  CI wiring was added 2026-08-22 by running these exact commands
locally and reading their exit codes and GATE-COUNT lines -- it has
not yet been observed to pass on an actual GitHub Actions runner,
whose toolchain (Emacs version, `node`, `cc`/`objcopy`) can differ
from this checkout's.

`verify` is the only command whose exit code answers "is the tree good".
Every other command reports on itself; `verify` also knows which gates
produced no report at all.  See `tools/ai/README.md` for the report
contract, the `GATE-COUNT` line that brings an existing Makefile target
under it, and `bench-compare.sh` for measurements — which have a third
outcome of their own, since a ratio the machine invalidated is neither
a pass nor a failure.

The root `Makefile` still holds the real build, the standalone smokes and
the release targets.  Use it directly for those; `nelisp-ai.sh` does not
wrap them yet.

## Rules that exist because each was broken here

1. **A gate that executed zero cases is not green.**  A CI gate placed
   behind an already-red target never ran once and was reported as
   passing for its whole life.  A `test/*.el` glob swept in driver
   scripts, defined no test, and failed with an opaque exit code.  This
   is why gates report counts and why `tools/ai/gates.expected` exists.
2. **Verify in the configuration the user actually runs.**  An IME engine
   was validated by overriding the runner through an environment
   variable while users selected it through the registry.  The registry
   path was never exercised and shipped broken.
3. **A measurement is invalid unless its baseline is.**  A 2.5x
   "regression" was background load; a 1.00x "parity" was the same
   program compiled twice and compared with itself.  Re-measure the
   baseline, check that the two sides differ, and record what else was
   running.
4. **Read values out of files, not out of terminal output.**  Use
   `nelisp-ai.sh probe EXPR`, which writes stdout, stderr and the binary
   identity into a directory and prints only its path.  `tail -1` has
   returned the shell's own echo here more than once.
5. **Name the artifact a number came from.**  `target/` holds a dozen
   experimental builds at once; `doctor` and `probe` both record the
   binary's hash and size.  When reading a disassembly, cut the slice by
   the manifest's offset and size — reading by eye produced two confident
   and wrong diagnoses of the same fault in one day.
6. **Check `git worktree list` before switching branches.**  A dozen and
   more worktrees are attached to this repository at any time, and
   another session may already hold the branch you are about to check
   out.  STATUS counts them for you.
7. **Record generated data recipes next to the generator.**  A dictionary
   was nearly shipped at 60% of its intended size because the real
   two-input recipe lived only in a session transcript.

## Where things are

| path | what |
|---|---|
| `src/` | NeLisp core (reader, eval, allocator, ...) |
| `lisp/` | AOT compiler, assemblers, code generation |
| `packages/` | optional libraries: json, http, sqlite, network, process, x11, ... |
| `packages/nelisp-pkg/` | the package graph: `make pkg-graph` derives it and fails on a cycle |
| `test/` | ERT, `*-test.el` only — other names are not collected |
| `docs/design/` | numbered design documents; declare state with `#+STATUS:` |
| `docs/runtime-limitations.md` | what compiled code does *not* do like C |
| `recipes/` | how to build an application or service on NeLisp |
| `tools/ai/` | the tooling this file describes |
| `target/` | build output, gate reports, STATUS — untracked, per machine |

## Building something with NeLisp

Start from `recipes/README.org`, which lists the application shapes that
are known to work today and the ones that are not viable yet, with the
measurement behind each verdict.  Copy a recipe's `skeleton/`, then run
its `verify.sh` before writing anything of your own — a recipe that
cannot pass its own smoke on your machine is telling you something.

```sh
tools/ai/nelisp-ai.sh recipes    # every recipe smoke, against target/nelisp
```

Each smoke skips with a reason when the binary is absent, so this is
also the quickest way to find out which shapes your build supports.
