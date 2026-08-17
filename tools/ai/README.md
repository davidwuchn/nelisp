# tools/ai — gate reports and the status snapshot

## Why counts instead of exit codes

An exit code has two states.  A check has three: it passed, it failed, or
it never ran.  The third state is invisible to `$?`, and it is the one
that has actually cost time in this repository:

- a CI gate was appended after a target that was already red, so the job
  stopped before reaching it — it never executed once and was counted as
  passing for its entire life;
- a `wildcard test/*.el` pulled non-ERT driver scripts into the load
  list, the batch run died before defining a single test, and the result
  surfaced as `Error 127` rather than as "0 tests";
- three standalone smokes invoked a Linux binary on Windows, failed
  every run, and were ignored by everyone because they always failed.

So every gate here reports how many cases it executed, and the
aggregator, not the gate, decides the verdict.

## The report

One JSON file per gate in `target/gates/<name>.json`:

```json
{
  "schema": "nelisp-gate/1",
  "name": "ert-full",
  "kind": "ert",
  "status": "pass",
  "ran": 4873,
  "passed": 4873,
  "failed": 0,
  "skipped": 143,
  "reason": "",
  "command": "tools/ai/nelisp-ai.sh test",
  "duration_ms": 412300,
  "finished": "2026-08-17T17:12:29+0900",
  "host": "THINKPAD-E14-GE"
}
```

Status is derived, in this order:

| condition | status |
|---|---|
| non-empty `reason` and `failed` = 0 | `skip` — an explicit, reasoned skip |
| `failed` > 0 | `fail` |
| `ran` = 0 | `fail` — wired up, never exercised |
| otherwise | `pass` |

`ran` counts cases *executed*.  For ERT that is `total - skipped`, so a
suite in which everything skipped reports `ran` = 0 and fails.  A gate
that legitimately cannot run on this host says so with `--reason`, which
produces `skip`: loud, attributable, and distinct from both green and
red.  A skip with no reason is indistinguishable from a gate that quietly
stopped working, so it is rejected.

## The manifest

`gates.expected` lists the gates that must have produced a report.  This
is the half an exit code cannot supply: without it, "no report" and
"nothing to report" look identical, which is exactly how a gate can be
green and absent at the same time.  A trailing `?` marks a gate optional.

## Emitting a report

From Elisp:

```elisp
(require 'nelisp-gate-lib)
(nelisp-gate-emit :name "my-gate" :kind "smoke"
                  :ran 20 :passed 20 :failed 0
                  :command "make my-gate")
```

From shell — the usual case when wrapping an existing Makefile target:

```sh
tools/ai/gate-report.sh --name standalone-reader --kind smoke \
    --ran "$cases" --passed "$ok" --failed "$bad" \
    --command "make standalone-reader-test"

# or, when the gate cannot run here at all:
tools/ai/gate-report.sh --name standalone-reader --reason \
    "linux ELF, host is windows-x86_64"
```

Pass a real count.  A hard-coded `--ran 1` reintroduces precisely the
blindness this exists to remove.

## Wrapping a command: the GATE-COUNT line

Most existing checks already know what they examined; they just do not
say so. `make parens-check` scans 417 files and, on a clean tree,
prints nothing at all — indistinguishable from a run whose file list
came back empty.

The cheap fix is one line at the end of the tool:

```elisp
(princ (format "GATE-COUNT checked=%d findings=%d\n"
               (length paths) (length findings)))
```

and then:

```sh
tools/ai/nelisp-ai.sh gate parens-check -- make parens-check
```

The wrapper runs the command, reads the last `GATE-COUNT` line, and
reports `ran = checked`. **A missing GATE-COUNT line is a failure** —
rather than assuming the command checked something, the wrapper says it
refused to answer. `checked` counts files or cases; `findings` is
informational, because a ratchet gate legitimately passes with findings
below its baseline.

## Measurements: bench-compare.sh

A benchmark has a third outcome too: it can produce a number that the
machine invalidated. `tools/ai/bench-compare.sh` reports that as a
`skip` with the reason, never as a pass.

```sh
tools/ai/bench-compare.sh --name bench-borrow-check \
    --base      'PROBE_ARM=plain   PROBE_ITERATIONS=%N% nelisp --load probe.el' \
    --candidate 'PROBE_ARM=checked PROBE_ITERATIONS=%N% nelisp --load probe.el'
```

Three guards, each of which corresponds to a real wrong answer this
repository has published:

| guard | what it caught |
|---|---|
| slope: run each arm at `n=0` and `n=N`, subtract | start-up counted as work |
| drift: run the base arm twice at `n=N` | a "2.5x regression" that was background load |
| identity: commands, and optionally artifact digests, must differ | a "1.00x parity" between one program and itself |

## Bringing an existing gate under the contract

1. Make the gate print or return a case count instead of only exiting.
2. Call `gate-report.sh` at the end of the target, on both paths.
3. Move its name above the comment block in `gates.expected`.
4. Run `nelisp-ai.sh verify` and confirm the gate appears in the table.

## Files

| file | role |
|---|---|
| `nelisp-ai.sh` | the entry point; `help` lists commands |
| `bench-compare.sh` | two-arm measurement with slope, drift and identity guards |
| `nelisp-gate-lib.el` | report writer for Elisp gates |
| `nelisp-ert-gate.el` | ERT batch runner that reports executed counts |
| `gate-report.sh` | report writer for shell gates |
| `nelisp-verify.el` | aggregator, manifest check, verdict |
| `nelisp-status.el` | generates `target/ai/STATUS.{json,md}` |
| `gates.expected` | which gates must exist |

Reports and STATUS live under `target/` — untracked and per machine, so
that a snapshot can never drift away from the tree it describes.  That
drift is the failure this tooling was built to end; committing its output
would recreate it.
