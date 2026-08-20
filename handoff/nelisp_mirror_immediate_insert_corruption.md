# Inserting a mirror entry with an immediate function cell destroys unrelated bindings

Status: **open**.  Found 2026-08-20 while chasing the last generative-differential
disagreement.  Not fixed here — the accompanying differential fix only stops
`fset` from *reaching* the broken path for the common `nil` case.

## What happens

`(fset 'FRESH-SYMBOL V)` where V is an immediate (tag 0 `nil`, tag 1 `t`,
tag 2 integer) and FRESH-SYMBOL has no mirror entry yet takes the insert path
(`nl_apply_do_fset` -> `nelisp_mirror_set_function_or_insert` ->
`nelisp_mirror_alloc_entry` + `nelisp_mirror_bucket_prepend`).  The symbol
itself binds correctly, but an *unrelated* global function binding disappears.

Measured on `target/nelisp` at 13217c44d, over the 468 `defun` names in
`scripts/nelisp-stdlib-prelude.el` (count = names for which `fboundp` is nil):

| stored value          | inserts | bindings lost |
|-----------------------|---------|---------------|
| `5`      (Int, tag 2) | 6       | 2             |
| `nil`    (Nil, tag 0) | 6       | 3             |
| `"s"`    (Str, tag 5) | 6       | 0             |
| `(lambda (x) x)`      | 6       | 0             |
| `'car`   (Symbol)     | 6       | 0             |

Heap-tagged values are clean; immediates are not.  Interleaving the inserts
with a walk over those 468 names **segfaults** (exit 139) after two or three
inserts, and one run answered `fboundp` = t for a name that is genuinely void,
so lookups can also return a wrong entry before the crash.

## Reproducer

```sh
python3 - <<'PY' > /tmp/repro.el
import re
names = sorted(set(re.findall(r"^\s*\(defun ([^\s()]+)",
                              open("scripts/nelisp-stdlib-prelude.el").read(), re.M)))
print("(defvar ns '(" + " ".join(names) + "))")
print('(defun nvoid () (let ((n 0)) (dolist (x ns) (unless (fboundp x) (setq n (1+ n)))) n))')
print('(princ (format "pre=%S" (nvoid)))')
for i in range(6):
    print("(fset 'gi%d 5)" % i)
print('(princ (format " post=%S\\n" (nvoid)))')
PY
mkdir -p /tmp/probe-run && cd /tmp/probe-run && "$OLDPWD/target/nelisp" --load /tmp/repro.el
```

`pre=1 post=3`.  Replace `5` with `"s"` and it is `pre=1 post=1`.

## Where to look

* `lisp/nelisp-cc-mirror-alloc-entry.el` — the `and` chain over `record-make`
  + four `record-slot-set`.  Its docstring asserts "All sub-ops materialise
  non-zero rax sentinels so the `and' value-form chain threads through"; if
  `record-slot-set` returns 0 for an immediate the chain short-circuits and
  `nelisp_mirror_bucket_prepend` never runs.  That was NOT observed (the
  symbol does bind), so the sentinel claim needs measuring rather than
  assuming — it is the only step in the path that sees the value's tag.
* `lisp/nelisp-cc-mirror-bucket-prepend.el` — `vector-slot-set` drops the old
  bucket head after `cons-set-cdr` clones it.  If that clone does not bump the
  refcount of a dump-baked chain, the drop frees entries that are still
  reachable, which matches "one unrelated binding dies per insert" and the
  later use-after-free crash.
* A stride mismatch worth ruling out: `nl_alloc_vector` allocates `cap*8` and
  `vector-ref-ptr` reads at `idx*8`, while the registry comment for
  `nl_vector_set_slot` in `scripts/compile-elisp-objects.el` still says it
  "writes 32 bytes to data_ptr + n*32".  One of the two is stale.

## Why the differential did not catch it

The generative fuzz runs each case in a fresh process, so a lost binding rarely
has a later case that needs it.  The one case that did surface
(`(seq-do 'foo (list 'quote 'sym))` reporting `void-function nil`) was a
*different* bug in the same area, fixed alongside this note.
