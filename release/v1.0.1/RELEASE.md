# NeLisp v1.0.1

**Release date**: 2026-08-26
**Tag**: `v1.0.1`
**Previous**: `v1.0.0` (same day)

> Non-native English author note: phrasing edited with LLM assistance; the
> technical claims are mine and every figure was measured on this tree.

A same-day follow-up to v1.0.0. Three defects that v1.0.0's own change --
turning the mid-form collector on by default -- brought into the open, plus
the in-process `.neln` loader that the collector change was blocking.

## The loader now runs any artifact, read at run time

v1.0.0 shipped a loader, but as a demo: the artifact's bytes and its externs'
addresses were baked into the binary at build time, so it could run exactly
one function. Everything that had to vary was fixed before the reader was
built.

`lisp/nelisp-native-load.el` drives the same mechanism from data read at run
time — mmap a page, write the text into it, patch relocations, build stubs for
the externs, enter through `ptr-call`. No linker, no `cc`, no subprocess.

## Defects fixed

**`pcase` refused `(cl-type TYPE)`.** `(pcase 5 ((cl-type integer) :int))`
signalled `Unknown cl-type pattern` where Emacs answers `:int`. Notably
`emacs-parity` did not catch this: it compares 19,995 behaviours and this was
not among them, so the divergence sat behind a green gate.

**`base64-decode-string` returned characters, not bytes.** Decoding `"yMnK"`
gave `(195 136 195 137 195 138)` where every other base64 gives
`(200 201 202)` — each byte ≥ 128 came back as its two-byte UTF-8 form, so the
pair did not round-trip for any binary input. The encoder had already been
fixed; only half the pair had been. Found while verifying a compiled
artifact's own recorded sha256 against the bytes it was computed from: the
file was intact and only this runtime's decode disagreed.

**The loader's digest buffer was not a GC root.** `alloc-bytes` returns a raw
pointer the collector knows nothing about, and the digest helper filled it one
byte at a time across 1152 iterations of a `while` — whose backedge is a
mid-form safepoint. A collection partway through reclaimed the buffer, and the
same intact artifact digested to `27c76247`, `a88c7b03`, `5a66d5e0` on
successive runs where its real digest is `42d6a0bf`. Every-run-different is
what reading reissued storage looks like. This could not happen before
v1.0.0, because the collector did not run by default.

**The native harness's slot registry was a fixed 64.** Its own comment said
"about 46 usable after the boundary and callback slots" and "a loop that boxes
a value per iteration outruns it in tens of iterations" — which is every tight
arithmetic loop. Grown on demand instead.

## Also

- `stage-d-v3.0 standalone parity` had failed 12 runs consecutively without
  testing anything: it demanded a `main` branch from a sibling repository
  that is on `master`, so it died before cloning. It now probes for a usable
  default branch. See *Known issues*.
- Doc 200 records a defect this release does NOT fix; see below.

## Known issues

**macOS aarch64: the `boxed` parity case segfaults.** With the clone failure
above fixed, that workflow reached its actual tests for the first time, and
one of roughly two dozen cases fails: `boxed -> exit 139 (expected 121)`. This
is not a regression from v1.0.0 — it was equally true then and simply
unreachable, because the job never got past cloning. Linux and Windows are
unaffected, and the six-lane `ci.yml` matrix is green.

**Unibyte strings are not a distinct representation.** `(unibyte-string 227
129 130)` and `"あ"` are `equal` on this runtime; a real Emacs answers `nil`.
The visible symptom is `append`, which answers `(521 640 0)` for
`(unibyte-string 200 201 202)` where Emacs answers `(200 201 202)`. Fixing
`append` alone is the wrong move — the same root reaches `concat`,
`substring`, `aref`, `equal`, `sxhash` and the printer, and 59 code lines
across ~24 files test the string tag today. `docs/design/200-unibyte-string-
representation.org` records the measurement, quotes Emacs 31.1's own NEWS on
the invariant it wants to keep, and states why this was not folded into a
release that shipped the same day.

## Verification

preflight, all 16 gates clear: `emacs-parity` 19,995 checks 0 findings;
`ert-full` 0 unexpected; `neln-loader-test` 16/16 with the digest stable
across five runs; `check-tier` PASS including `gate-mutation`. CI green on
Linux/macOS/Windows × Emacs 29.4/30.1 plus the fast `gates` job.
