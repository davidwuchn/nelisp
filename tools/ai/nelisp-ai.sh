#!/bin/sh
# nelisp-ai.sh --- one entry point for working in this repository.
#
# The root Makefile has 76 targets and no `help'.  This script is not a
# replacement for it; it is the short list of things worth running on
# every change, wired to emit machine-checkable gate reports instead of
# bare exit codes.  See AI.md for the workflow and tools/ai/README.md for
# the report contract.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

EMACS=${EMACS:-emacs}
GATE_DIR=${NELISP_GATE_DIR:-target/gates}
export NELISP_GATE_DIR="$GATE_DIR"

# Mirrors the load path the root Makefile builds for `test'.
load_path_args() {
    printf -- '-L lisp -L src -L test -L bench'
    for d in packages/*/src packages/*/test; do
        [ -d "$d" ] && printf -- ' -L %s' "$d"
    done
}

test_files() {
    # Same shape as the Makefile's TESTS: `*-test.el' only, soak excluded.
    # The `-test.el' suffix is load-bearing — a plain `test/*.el' glob in a
    # sibling repository swept in driver scripts, the batch run died before
    # defining any test, and the suite reported an exit code instead of
    # "0 tests".
    ls test/nelisp*-test.el packages/*/test/nelisp*-test.el \
       packages/*/test/nl-*-test.el 2>/dev/null \
        | grep -v 'nelisp-worker-soak-test\.el$' || true
}

nelisp_binary() {
    if [ -n "${NELISP_BIN:-}" ]; then printf '%s' "$NELISP_BIN"; return 0; fi
    for candidate in target/nelisp.exe target/nelisp; do
        [ -x "$candidate" ] || [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

binary_identity() {
    # Which binary produced a number matters as much as the number.  This
    # repository keeps a dozen experimental builds in target/ at once.
    bin=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha=$(sha256sum "$bin" | cut -c1-16)
    else
        sha="nosha"
    fi
    size=$(wc -c < "$bin" | tr -d ' ')
    printf '%s sha=%s size=%s' "$bin" "$sha" "$size"
}

cmd_help() {
    cat <<'EOF'
usage: tools/ai/nelisp-ai.sh <command> [args]

  status              regenerate target/ai/STATUS.{json,md} — read this first
  verify              aggregate gate reports and print one verdict
  test                run the full ERT suite as gate "ert-full"
  test-one FILE...    run selected test files as gate "ert-focus"
  compile             byte-compile with error-on-warn as gate "compile"
  ns [FILE...]        namespace check (defaults to the recipe skeletons)
  probe EXPR          evaluate EXPR in the standalone runtime, output to files
  doctor              print the toolchain and binary identity of this checkout
  gates-clean         delete every gate report (they are per-machine)

Every command that checks something writes a report into target/gates/.
`verify' is the only command whose exit code you should trust for "is the
tree good", because it is the only one that also knows which gates are
missing entirely.
EOF
}

cmd_status() {
    "$EMACS" --batch -Q -l "$here/nelisp-status.el" -f nelisp-status-run
    printf '\n'
    cat target/ai/STATUS.md
}

cmd_verify() {
    "$EMACS" --batch -Q -l "$here/nelisp-verify.el" -f nelisp-verify-run
}

run_ert_gate() {
    gate_name=$1
    shift
    files=$*
    if [ -z "$(printf '%s' "$files" | tr -d ' \n')" ]; then
        "$here/gate-report.sh" --name "$gate_name" --kind ert --ran 0 \
            --failed 1 --reason "no test file matched; nothing was run" \
            --command "nelisp-ai.sh $gate_name"
        exit 1
    fi
    loads=""
    for f in $files; do loads="$loads -l $f"; done
    started=$(date +%s)
    set +e
    # shellcheck disable=SC2046,SC2086
    NELISP_GATE_NAME="$gate_name" \
    NELISP_GATE_COMMAND="tools/ai/nelisp-ai.sh $gate_name" \
        "$EMACS" --batch -Q $(load_path_args) \
            --eval '(setq load-prefer-newer t)' \
            -l ert $loads \
            -l "$here/nelisp-ert-gate.el" -f nelisp-ert-gate-run
    code=$?
    set -e
    printf 'elapsed: %ss\n' "$(( $(date +%s) - started ))"
    return $code
}

cmd_test() {
    run_ert_gate ert-full "$(test_files)"
}

cmd_test_one() {
    [ $# -gt 0 ] || { echo "usage: nelisp-ai.sh test-one test/nelisp-FOO-test.el" >&2; exit 2; }
    run_ert_gate ert-focus "$*"
}

cmd_compile() {
    # Mirrors the root Makefile's SRCS + PACKAGE_SRCS, including the
    # nl-* packages.  Keep the two in step: a glob that quietly stops
    # matching is the same failure this harness exists to catch, and it
    # is easiest to introduce right here.
    srcs=$(ls src/nelisp*.el packages/*/src/nelisp*.el \
              packages/*/src/nl-*.el 2>/dev/null || true)
    if [ -z "$srcs" ]; then
        "$here/gate-report.sh" --name compile --kind lint --ran 0 --failed 1 \
            --reason "no source file matched" --command "nelisp-ai.sh compile"
        exit 1
    fi
    started=$(date +%s)
    set +e
    # shellcheck disable=SC2046,SC2086
    "$EMACS" --batch -Q -L src $(load_path_args) \
        --eval '(setq byte-compile-error-on-warn t)' \
        -f batch-byte-compile $srcs
    code=$?
    set -e
    produced=$(ls src/nelisp*.elc packages/*/src/nelisp*.elc \
                  packages/*/src/nl-*.elc 2>/dev/null | wc -l | tr -d ' ')
    # Byte-compiled artifacts are removed again unless asked for.  This
    # is a lint check, and the root Makefile's `test' target deletes
    # them before every run for a documented reason: byte-compiled
    # `nelisp-eval.el' adds host stack frames that trip
    # `max-lisp-eval-depth' inside the self-host probes.  Leaving .elc
    # behind would make a later test run depend on whether someone had
    # linted first.  NELISP_KEEP_ELC=1 opts out.
    if [ -z "${NELISP_KEEP_ELC:-}" ]; then
        rm -f src/nelisp*.elc packages/*/src/nelisp*.elc packages/*/src/nl-*.elc
        printf 'removed %s .elc (set NELISP_KEEP_ELC=1 to keep them)\n' "$produced"
    fi
    "$here/gate-report.sh" --name compile --kind lint \
        --ran "$produced" --passed "$produced" \
        --failed "$([ $code -eq 0 ] && echo 0 || echo 1)" \
        --duration-ms "$(( ($(date +%s) - started) * 1000 ))" \
        --command "nelisp-ai.sh compile"
}

cmd_ns() {
    # Elisp has one obarray, so a second definition of a name silently
    # wins.  `nl-ns' reports the boundaries the language cannot enforce.
    # Whole-tree checking is `make ns-inventory', which ratchets against
    # a baseline; this is for a small set that should simply be clean.
    if [ $# -gt 0 ]; then
        files=$*
        gate_name=${NELISP_GATE_NAME:-ns}
    else
        files=$(ls recipes/*/skeleton/*.el 2>/dev/null || true)
        gate_name=${NELISP_GATE_NAME:-ns-recipes}
    fi
    if [ -z "$(printf '%s' "$files" | tr -d ' \n')" ]; then
        "$here/gate-report.sh" --name "$gate_name" --kind ns --ran 0 \
            --failed 1 --reason "no file matched; nothing was checked" \
            --command "nelisp-ai.sh ns"
        exit 1
    fi
    # shellcheck disable=SC2086
    NELISP_GATE_NAME="$gate_name" \
        "$EMACS" --batch -Q -L packages/nl-prelude/src -L packages/nl-ns/src \
            -l "$here/nelisp-ns-check.el" -f nelisp-ns-check-run $files
}

cmd_probe() {
    [ $# -gt 0 ] || { echo "usage: nelisp-ai.sh probe '(+ 40 2)'" >&2; exit 2; }
    expr=$1
    bin=$(nelisp_binary) || { echo "no nelisp binary in target/; set NELISP_BIN" >&2; exit 2; }
    dir="target/ai/probe/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$dir"
    printf '%s' "$expr" > "$dir/expr.el"
    set +e
    "$bin" --eval "$expr" > "$dir/stdout.txt" 2> "$dir/stderr.txt"
    code=$?
    set -e
    {
        printf 'expr_file: %s\n' "$dir/expr.el"
        printf 'exit: %s\n' "$code"
        printf 'binary: %s\n' "$(binary_identity "$bin")"
        printf 'finished: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    } > "$dir/meta.txt"
    # Only the path goes to stdout.  Reading the value out of a terminal
    # transcript is how `tail -1' ends up returning the shell's own echo,
    # and how oversized frames get truncated on the way back.
    printf '%s\n' "$dir"
}

cmd_doctor() {
    printf 'repo:        %s\n' "$root"
    printf 'branch:      %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    printf 'head:        %s\n' "$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
    printf 'worktrees:   %s\n' "$(git worktree list 2>/dev/null | wc -l | tr -d ' ')"
    printf 'emacs:       %s\n' "$("$EMACS" --version 2>&1 | head -1)"
    printf 'make:        %s\n' "$(make --version 2>&1 | head -1)"
    if bin=$(nelisp_binary); then
        printf 'nelisp:      %s\n' "$(binary_identity "$bin")"
        printf 'nelisp mtime:%s\n' " $(date -r "$bin" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo '?')"
    else
        printf 'nelisp:      (none in target/)\n'
    fi
    printf 'gate dir:    %s (%s report(s))\n' "$GATE_DIR" \
        "$(ls "$GATE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
}

cmd_gates_clean() {
    rm -f "$GATE_DIR"/*.json
    printf 'cleared %s\n' "$GATE_DIR"
}

command=${1:-help}
[ $# -gt 0 ] && shift || true
case "$command" in
    help|-h|--help) cmd_help ;;
    status)         cmd_status ;;
    verify)         cmd_verify ;;
    test)           cmd_test ;;
    test-one)       cmd_test_one "$@" ;;
    compile)        cmd_compile ;;
    ns)             cmd_ns "$@" ;;
    probe)          cmd_probe "$@" ;;
    doctor)         cmd_doctor ;;
    gates-clean)    cmd_gates_clean ;;
    *)              printf 'unknown command: %s\n\n' "$command" >&2; cmd_help >&2; exit 2 ;;
esac
