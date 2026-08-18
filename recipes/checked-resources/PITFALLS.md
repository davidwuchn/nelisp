# checked-resources — what bites, and how it looks when it does

## You cannot time anything from inside the runtime

`(current-time)` answers `(0 0 0 0)` and `(float-time)` answers nil on
the standalone binary — `fboundp` says both exist, they simply return
stubs. Any in-process benchmark built on them either aborts (`form
aborted without signal (rc=1)`, from arithmetic on nil) or silently
reports zero.

Time whole processes from outside and subtract an empty run of the same
arm to remove start-up. That is what `verify.sh` does.

## A ratio without a validity number is not a measurement

Two failures in this repository's history, both from real sessions:

- a 2.5x "regression" that was OneDrive and a crash-looping WSL process
  competing for the machine;
- a 1.00x "parity" between two fixtures that had compiled to byte-identical
  programs, so the benchmark was comparing one program with itself.

`tools/ai/bench-compare.sh` runs the base arm twice and prints the
drift. Past the limit it discards the ratio and reports a `skip` with
the reason instead of a number. Use that harness rather than writing
your own timing loop — a number you cannot trust is worse than no
number, because it gets quoted.

## The checker can be present and doing nothing

If your smoke only exercises legal borrows, it passes whether or not the
borrow checking works. `checked-conflict` exists to provoke a real
violation and require `nl-borrow-error`. It is the second check in
`verify.sh` and it is the load-bearing one.

## A wrong path in the load list is completely silent

`(load "packages/nl-safe/src/nl-safe.el" nil t)` with a path that does
not exist **returns t**. NOERROR is nil in that call, so Emacs would
signal `file-missing`; this runtime does not. Nothing is printed, the
script continues, and the first symptom is a `void-function` somewhere
that looks unrelated.

`probe.el` therefore asserts `featurep` after loading, and `verify.sh`
checks that assertion first. Keep both when you adapt this: the whole
point of loading by path is that you chose the paths, and nothing else
will tell you when one is wrong.

Relatedly, if you generate the list — `make -s pkg-load-order PKG=...` —
be aware that Emacs batch on Windows prints CRLF, so `for f in $(...)`
keeps a carriage return in every path. The two behaviours compose into
a script that loads nothing and reports success.

## `require` versus `load` for the nl-* packages

The skeleton loads its dependencies by explicit path. That is the
pattern the nl-* packages' own standalone smokes use, and it is version
independent: an older standalone binary (2026-08-14) answered `(require
'absent-feature)` with the feature name — success to every caller —
while `featurep` stayed nil. Current builds signal `file-missing`, which
is a real improvement, but `load` by path never depended on it.

## The violation log accumulates

`nl-safe-report-dump` appends. Run the smoke twice without clearing and
the violation count grows; a check written as "exactly 1" will fail on
the second run. `verify.sh` removes the log first and then asserts at
least one. If you want the corpus to accumulate across runs — which is
the point of it for the Phase 6 gate — do not delete it, and count
differently.

## `getenv` answers nil on Linux, so parameters go in as variables

The timed arms originally read `PROBE_ITERATIONS` from the environment.
On the Linux build `getenv` returns nil for everything — including
`HOME` — so every arm ran zero iterations and both arms measured
process start-up. The tell was that raising the count from 3000 to
120000 changed the wall time by nothing.

`arm.sh` now writes a driver that sets the parameters as variables and
loads the probe. Do the same in anything you adapt: the environment is
not a portable channel into this runtime.

## Do not carry the ratio anywhere

Six valid runs on Windows gave 1.40x to 1.64x — a 17% spread, the
widest taken while other work was running. Linux gave 1.86x. One loop
shape, in the interpreter, on two hosts.

The Doc 170 §9 figure (4.99x against a ≤1.15x budget) measures
AOT-compiled borrows where type checks dominate. Quoting either number
in place of the other is how a design decision gets made on the wrong
data.
