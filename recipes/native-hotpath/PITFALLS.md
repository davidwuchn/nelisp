# native-hotpath — what bites, and how it looks when it does

## `native-exec-elisp-artifact: ... phase=native-exec: (error)`

On Windows this is the expected outcome today, not a bug in your
artifact. Native execution is gated to linux-x86_64: every test in
`test/nelisp-artifact-native-exec-test.el` carries `skip-unless` a
linux-x86_64 predicate. The artifact still compiles correctly on
Windows — `inspect-elisp-artifact` will show your functions with
`:native t` — it just cannot be run there.

The error text carries no cause. Do not spend an afternoon on it before
checking the platform.

## `audit-elisp-artifacts` exits 1 and prints nothing

Measured on a Windows build (2026-08-17), for a `.neln`, for its `.el`
source, and for the containing directory. No output on stdout or
stderr, exit 1 in all three forms.

This recipe therefore does **not** use `audit` as a check. If you were
planning to gate CI on it, verify it works on your platform first — a
command that fails silently is worse than one that fails loudly, and
this one currently cannot be distinguished from "your artifact is bad".

## The manifest says `:native t` for things you expected to fall back

`current-time` has no AOT grammar, yet a file whose only function calls
it still reports `:native t` for that function. So `:native t` does not
mean "contains no runtime dispatch" — it is a statement about the
function being emitted into the native section, not about everything it
calls.

If you need to know that a specific call was lowered rather than
dispatched, measure it. Do not read it off this field.

## A green manifest check that greps for nothing

`grep ':name "foo" :native t'` passes silently forever if the field is
renamed, the symbol is misspelled, or inspection output changes shape.
`verify.sh` includes a sensitivity control — it asks about a symbol that
does not exist and requires a negative answer. Keep an equivalent when
you adapt it. This is the same failure mode as a test suite that runs
zero tests.

## The artifact is ELF even on Windows

`:object-format nelisp-aot-elf-v1` with `:target "x86_64-w64-mingw32"`.
That is what the compiler emits today; it is consistent with execution
being available only on Linux. Do not hand a `.neln` to a native
Windows toolchain expecting a COFF object.

## Link-time dependencies are not in the file

An artifact that calls libc emits relocations a linker has to resolve.
The `.el` and the `.neln` alone do not run that code — unresolved
symbols fault at run time, not at compile time.
`docs/runtime-limitations.md` §B is the reference.
