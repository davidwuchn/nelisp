# NeLisp v1.2.1

A parity release.  Six places where the standalone reader answered
something plausible instead of what host Emacs answers, and each of them
had already cost a consumer a day somewhere far from the cause.  No new
subsystem, no new target; the same 47 reader smokes on windows-x86_64 and
linux-x86_64, plus one new gate that holds all six.

The occasion was anvil.el's standalone MCP server, which is now the
repository's most demanding downstream: it loads a hundred-odd elisp files
through Layer 2 (`nelisp-emacs`) before it serves a single request, so it
reaches parts of the host contract nothing else here does.

| | v1.2.0 | v1.2.1 |
|---|---|---|
| reader smokes, windows-x86_64 / linux-x86_64 | 47 / 47 | 47 / 47 |
| host-parity gate | none | `standalone-reader-host-parity-smoke` |
| `unsafe-inventory` | 759 = baseline | 759 = baseline |

## The six

**1. `load` binds `load-file-name`, and restores it.**  It never bound it,
so the `(or load-file-name buffer-file-name)` idiom that Emacs sources are
built on saw nil everywhere.  Layer 2's own `emacs-init.el` uses exactly
that to put its `src/` on `load-path`; with the variable nil that step was
a silent no-op and the very next `require` died `file-missing`.  The
binding is the RESOLVED path (below), and nesting restores the outer
value.  The restore needs no unwind-protect and does not have one: a
signal here is a flag and a stash, not a stack unwind, so the loop returns
a code either way and the restore always runs.

**2. `load` searches `load-path` for a relative name.**  Only `require`
did, so `(load "subr-x")` failed where `(require 'subr-x)` worked.  Now
`DIR/NAME.el` then `DIR/NAME`, Emacs's own order, and a name that carries
its own root -- a leading `/` or `\`, or a `X:` drive prefix -- is never
searched, also as in Emacs.

**3. `kill-emacs` stops the process.**  There was no immediate-exit
primitive at all: the reader's `exit` only RECORDS a status, and execution
carried on to the end of the form and through the rest of the file.
`nelisp--exit-process` is the immediate one (`exit_group` / `ExitProcess`),
`kill-emacs` is its Emacs-named wrapper, and `exit`'s status-only contract
is untouched because the driver's own top-level loop is built on it.

**4. `make-directory` creates the directory it was asked for.**  Three
defects, and the first two hid the third: the PARENTS walk rebuilt every
path as absolute-POSIX (a relative `a/b` became `/a`, a Windows `C:/x`
became `/C:/x`), every result was discarded so failure was
indistinguishable from success, and on windows-x86_64 the underlying
`mkdir` was an unconditional `-ENOSYS` -- a silent no-op that still
answered its own argument.  Windows now has real `CreateDirectoryW` /
`RemoveDirectoryW` / `DeleteFileW` arms with their Win32 errors mapped to
POSIX errno, and `make-directory` returns nil, keeps the path's own root,
and tells `file-already-exists` apart from every other failure.

**5. `rdf` answers nil for a file it cannot open.**  It answered the empty
string -- the same value an empty file produces.  `load` reported success
for a path that does not exist (already worked around inside `load` by
probing first), and Layer 2's `emacs-fileio-rdf-file-exists-p`, which asks
exactly `(stringp (rdf F))`, answered t for every name, so `require` took
its literal-path branch and every feature after it failed `file-missing`.

**6. `encode-coding-string` / `decode-coding-string` are a real pair.**
Both were the identity.  The CONVERSION is genuinely a no-op -- a string's
payload is already its UTF-8 bytes -- but the RESULT KIND is the whole
observable difference: `(length (encode-coding-string "日" 'utf-8 t))`
answered 1 where Emacs answers 3, and every consumer that round-trips
through the pair had reached for `string-as-unibyte` / `string-as-multibyte`
directly instead.

## Fixed alongside

- **Layer 2 `processp` disowned network processes** (`nelisp-emacs`).
  `emacs-process-builtins` force-installs its own `processp` on the
  standalone reader, and that one did not know the process adapter's
  `[network-process ...]` shape -- its own commentary defers network
  processes -- while the reader's prelude `processp` did.  The prelude's
  `process-put` / `process-get` then signalled `wrong-type-argument
  processp` on a listener, which killed anvil's socket daemon the moment it
  bound one, on Linux and Windows both.

## How it is verified

`standalone-reader-host-parity-smoke` is one new target holding all six,
and it asserts VALUES rather than exit status: every one of these answered
something plausible-looking before, which is exactly how they survived a
release.  Two `tools/gate-mutations.txt` rows restore v1.2.0's behaviour
for gaps 1 and 6 -- the gate has to notice a regression TO THE PREVIOUS
RELEASE, not just an arbitrary edit -- and both were run: each turns the
gate red, and the restore was checked byte-identical.

Also green on this change: `standalone-reader-smokes` 47/47 findings=0 on
windows-x86_64, `standalone-reader-ffi-smoke` on both targets,
`unsafe-inventory` 759 = baseline (the new units are quoted, so the gate
does not move), `ns-gate` 2278 findings=0, `compile` 117/0,
`version-consistency` all 9 sites.

## Known issues

- `gate-mutation`'s full battery was not run on a Windows host for this
  change: it rebuilds per row, and its children outlive a stop -- which is
  how an injected row reached a commit earlier the same day.  The two new
  rows were verified individually instead, with a controlled restore.  The
  Linux CI lane owns the battery.
- anvil's TCP daemon gets further than it did (it binds, listens and
  accepts) but does not yet complete a request; that is downstream wiring,
  not a reader defect.
- Everything v1.2.0's "Known issues" listed still stands: the Windows
  process gates' thin 0.44 s headroom, `tls-smoke`'s network gating, and
  the standalone binary not being byte-reproducible.
