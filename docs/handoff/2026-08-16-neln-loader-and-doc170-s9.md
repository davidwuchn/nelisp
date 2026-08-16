# Handoff: in-process `.neln` loader, and the Doc 170 §9 measurement

Branch `feat/aot-dynamic-user-calls`, 11 commits ahead of `31f75537`.
Everything below is on that branch. Nothing is merged to `main`.

The goal that is still open: **measure the Doc 170 §9 borrow budget on the
AOT native path.** Everything else here exists because it was in the way.

---

## 1. State: what works

```
make test                      5001 tests, 4648 as expected, 0 unexpected, 353 skipped
make compile                   clean (includes the nl-check gate)
make neln-loader-test          10 cases, 0 failures
make standalone-reader-realrt-smoke   exit 42
```

`lisp/nelisp-native-load.el` reads a `.neln` at run time and executes its
native code inside the standalone reader — no linker, no `cc`, no
subprocess. Ten shapes pass: both calling conventions, arity 0 through 6,
a string in and a string out, `t` and `nil`, and a `calln`-plus-literal
body at 427 bytes.

Commits, oldest first:

| commit | what |
|---|---|
| `7e690a48` | `--dynamic-user-calls`: unresolvable user calls lower through the calln dispatcher, closing a unit's extern set over the runtime symbols |
| `8bd3f268` | native `nelisp_aot_builtin_calln` provider for the reader (the symbol did not exist) |
| `ddf192ee` | **fix**: a nested delegated call dispatched on the inner call's name; plus the loader generalisation (`data-addr` stubs, sizing from the artifact) |
| `e3a702a7` | **fix**: literal arguments to a delegated call were passed as raw untagged words |
| `e30ff0ab` | `nelisp--native-symbol-addr` — runtime symbol addresses for interpreted elisp |
| `a892332e` | the loader itself, plus tests in two halves |
| `46160af2` | Doc 142 §6.4 written up |
| `e9821ed0` | **fix**: three loader defects around vectors (see §4) |
| `f5278cc0` | §9 bench: helpers moved into the artifact's own unit |

---

## 2. The open problem

`make nl-safe-native-bench` compiles both sides of the §9 pair, loads
them, and segfaults on the first call.

Reduced as far as it goes, and the reduction is the interesting part:

```elisp
(defun vget      (n) (aref (vector 7 8 9) 0))   ; -> 7        works
(defun plainref  (n) (aref (vector 7 8 9) 1))   ; -> segfault
```

Those two artifacts are **identical in every measurable way**:

```
vget      rt=17  size=550  externs=(calln nl_alloc_symbol nl_alloc_vector
                                    nl_vector_set_slot nl_vector_slot_ptr)
plainref  rt=17  size=550  externs=(same)
```

Same slot count, same text size, same extern set. The only difference in
the source is the constant `0` versus `1`.

Reading element 0 works; reading element 1 faults. That is where to
start. Note the vector itself is built correctly — see §4.3 for how to
check that directly.

Also failing, all with the same smell:

```elisp
(defun letvec   (n) (let ((c (vector 7 8 9))) (aref c 1)))
(defun symvec   (n) (aref (vector 'nl--cell 7 0) 1))
(defun nestvec  (n) (aref (vector 1 (vector 7 8 9) 3) 0))
(defun vsetget  (n) (let ((v (vector 0 0 0))) (aset v 1 n) (aref v 1)))  ; -> nil, not a crash
```

`vsetget` returns `nil` rather than faulting, so `aset` lands somewhere
harmless. It may or may not be the same defect.

The §9 cell is `(vector 'nl--cell (vector 7 8 9) 0)`, so every one of
these has to work before the budget can be measured.

---

## 3. How to run things

Everything native runs on Linux x86_64. On this machine that is WSL
Debian; the repo is visible there at
`/mnt/c/Users/kuroz/Cowork/Notes/dev/nelisp-nl-ns` (a junction to
`D:\Cowork\Notes\dev`).

```sh
make standalone-reader          # ~3-4 min, rebuilds target/nelisp
make neln-loader-test           # the ten passing cases
make nl-safe-native-bench       # the §9 pair (currently faults)
make test-one FILE=test/nelisp-native-load-test.el
```

A reader rebuild is needed after touching anything under `scripts/` or
`lisp/nelisp-cc-*`. It is **not** needed after touching
`lisp/nelisp-native-load.el` — that is interpreted, loaded from disk each
run, so the edit-test loop there is seconds.

To run a one-off against the loader:

```sh
cat > /tmp/probe.el <<'EOF'
(load "/mnt/c/.../nelisp-nl-ns/lisp/nelisp-native-load.el")
(princ (format "%S\n" (nelisp-native-load-exec "/path/to/f.neln" "f" (list 1))))
EOF
./target/nelisp --load /tmp/probe.el
```

Compile a fixture with the host Emacs, not the reader:

```sh
emacs --batch -Q -L lisp -L src --eval '(progn
  (setq load-prefer-newer t)
  (require (quote nelisp-artifact))
  (require (quote nelisp-aot-compiler))
  (let ((nelisp-aot-compiler--dynamic-user-calls t))
    (nelisp-artifact-compile-file "/tmp/f.el" "/tmp/f.neln" nil nil nil nil nil (quote neln))))'
```

`--dynamic-user-calls` is what closes the extern set. Without it the unit
carries relocations naming elisp functions and the loader refuses it.

---

## 4. Techniques that worked

These are not obvious and each saved a lot of time.

### 4.1 Get the faulting address from `dmesg`

The reader dies with a bare "Segmentation fault". The kernel knows more:

```sh
./target/nelisp --load /tmp/probe.el; sleep 1
dmesg | grep 'nelisp\[.*segfault' | tail -1
```

gives `segfault at 8 ip 00000000007f06af`. Then

```sh
readelf -sW target/nelisp | grep -E ' nl_vector_slot_ptr$'
```

places `0x7f06af` inside `nl_vector_slot_ptr`, and `at 8` says it
dereferenced offset 8 of a null pointer. That turned "it crashes" into
"this function received a Sexp whose payload is null" in two commands.

### 4.2 Verify the loading before suspecting it

The handle exposes `:codepage`, `:stubs` and `:body-entry` for this. Read
the patched bytes back and follow each call:

- each stub's imm64 (at `codepage + stub_offset + 2`) should equal
  `nelisp--native-symbol-addr` for its name;
- each relocation site should hold opcode `0xE8` and a disp32 such that
  `site + 4 + disp == its stub`.

Doing this ruled the loader out for the vector case in one run, which is
what pointed at the semantics instead.

### 4.3 Read the built object out of memory

The loader leaves intermediates behind, so you can inspect what compiled
code actually built:

```elisp
(defvar H (nelisp-native-load-artifact "/tmp/vmake.neln" "vmake"))
(nelisp-native-load-box (plist-get H :arg-slots) 5)
(ptr-call (plist-get H :entry) (plist-get H :arg-slots) 0 0 0 0 0)
(defvar OUT (plist-get H :out))
(defvar BOX (ptr-read-u64 OUT 8))          ; Sexp::Vector payload
(defvar DATA (ptr-read-u64 BOX 8))         ; NlVector data pointer
(ptr-read-u64 DATA 0)                       ; element 0's word
```

A NeLisp integer immediate is `(value * 4) + 1`, so 7 reads as 29. This
is how "the vector is three Nils" was established — the word was 3, the
Nil immediate.

### 4.4 Disassemble the artifact text

```sh
emacs --batch -Q -L lisp -L src --eval '(progn
  (require (quote nelisp-artifact))
  (let* ((nat (plist-get (nelisp-artifact--read-payload "/tmp/f.neln") :native))
         (txt (base64-decode-string (plist-get nat :text-base64)))
         (coding-system-for-write (quote binary)))
    (write-region txt nil "/tmp/f.bin" nil (quote quiet))))'
objdump -b binary -m i386:x86-64 -M intel -D /tmp/f.bin
```

Frame slot index `i` sits at `[rbp - 8*(i+1)]`. For arity `a`, slots
`0..a-1` are the arguments and `a..a+16` are the boundary, in the order
`out mirror frames scratch name_slot callback-0 .. callback-11`. So
`[rbp-0x28]` in an arity-1 defun is `scratch`.

---

## 5. Traps

**Read the whole output.** Three wrong conclusions this session came from
truncating: `tail -20` on a test failure list hid the top of it, reading
only the first `sub rsp` of a prologue (there are three) produced a bogus
"the frame is too small" theory, and a `grep` filter over `make test`
returned nothing and looked like success.

**Do not batch reader probes in a shell loop.** Quoting through
`wsl -- bash -lc '... for e in "..."; do ./target/nelisp --eval "$e"; done'`
silently mangles the expressions and every case comes back `nil`. It
looked like a broken runtime twice. Write the probe to a file and
`--load` it.

**The reader has no `getenv`.** Pass paths by generating a prelude file
that `defvar`s them, which is what the make targets do.

**`base64-decode-string` returns a string whose bytes over 127 are UTF-8
encoded** in this runtime. Use `aref` (character at index), never
`string-byte` (which walks the encoding). This corrupted the text on the
code page with 137 arriving as 194 137.

**The reader's `nelisp_apply_function` does not look up user functions.**
It dispatches a fixed if-chain over `nelisp-standalone--reader-builtins`
and writes anything else to stderr. The general symbol lookup is in the
*host* elisp bridge, `nelisp-cc-runtime--aot-default-builtin-dispatchn`,
which is a different thing. This is why the §9 helpers had to move into
the artifact's own unit.

**`nelisp_aot_signal` does not exist in the reader**, so a unit
containing a compiled `signal` cannot be loaded at all.

**`emacs -Q --batch` without `load-prefer-newer`** picks up stale `.elc`.
Prefer `make test-one FILE=...`.

---

## 6. Facts about the loader worth knowing before editing it

**Two calling conventions, not recorded in the artifact.** A defun either
takes Sexp pointers and returns through rax-as-a-pointer, or takes raw
i64 and returns raw in rax. `param-class` is `gp` for both. The CLI
decides by trying the integer call and falling back; in-process a wrong
guess corrupts rather than errors, so `nelisp-native-load-abi` derives
it: no externs means integer, any extern means boxed.

**The result is in rax, not in `out`.** For a body ending in a delegated
call the two are the same pointer, which hid this until a body ended in
something else.

**`scratch` is a vector, and its elements must hold pointers.**
`nl_vector_slot_ptr` returns the stored word when it is a pointer and a
*fresh temporary* when it is an immediate. Compiled code fills an element
by calling it once for somewhere to write and again to hand that storage
to `nl_vector_set_slot`, which only works when both calls agree. Since
`nl_val_clone_into` folds nil, `t` and integers back to immediates, the
scratch elements are seeded with a string.

**Symbol addresses are indexed, not named.** `data-addr` is a
compile-time form, so `nelisp--native-symbol-addr` selects from a chain
fixed when the reader is built.
`nelisp-native-load-bridgeable-symbols` must stay identical, in order, to
`nelisp-standalone--reader-neln-bridgeable-symbols`; a test asserts it.

**`nl_alloc_consbox` and `nl_val_clone_into` exist in the reader but are
not in the bridgeable set.** Adding them (both lists, then rebuild) would
let cons-using artifacts load. Not needed for §9; noted because the
pre-flight check refuses them today and the refusal reads like a missing
feature rather than a decision.

---

## 7. What to do next

1. **Find why element index 1 faults and index 0 does not.** Start from
   the `vget` / `plainref` pair in §2 — identical artifacts, one
   constant apart. Disassemble both (§4.4) and diff. The answer is in
   the few instructions that differ.
2. Then `letvec`, `symvec`, `nestvec` — likely the same cause.
3. Then `aset` (`vsetget` returns `nil`), which the borrow needs for its
   state counter.
4. Then `make nl-safe-native-bench` should run, and §9 has its number.

The bench harness is already written and does not need changing:
`scripts/nl-safe-native-bench-fixtures.el` compiles the pair,
`bench/nl-safe-native-bench.el` times them and compares against the
1.15x budget, and both sides refuse to report if they disagree on the
value they compute.

One caveat about the fixture, already recorded in its header: the
helpers are nl-safe's fast path transcribed, and the branch that differs
is the one a passing run never takes — nl-safe signals there, the
fixture returns 0, because of the `nelisp_aot_signal` limit above.

---

## 8. Why this kept finding bugs

The loader that existed before was a demo: `(defun inc1 (x) (1+ x))`,
one call, no literal arguments, no cons, no vector, 122 bytes, with its
bytes and extern addresses baked into the reader at build time. Five
defects in the AOT and the loader had never been reached because nothing
had ever run anything else natively in-process.

That is worth keeping in mind while working through the list above: a
fault in this area is more likely to be a first visit than a regression.
