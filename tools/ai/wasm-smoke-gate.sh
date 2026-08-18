#!/bin/sh
# wasm-smoke-gate.sh --- run `make wasm-smoke' and report what it proved.
#
# The target compiles two Elisp functions to wasm32, validates each
# module and runs it under node.  It printed the results and nothing
# else, so a run that compiled nothing and a run that compiled both
# looked the same from outside.  This counts the modules that actually
# executed and returned the expected value.
#
# The expected results are the ones the target's own arguments ask for:
# f(42) = 42 and f-locals(9) = 9.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

set +e
make wasm-smoke > "$log" 2>&1
code=$?
set -e

cat "$log"

validated=$(grep -c '^validate=true$' "$log" || true)
correct=0
grep -q '^result=42$' "$log" && correct=$((correct + 1))
grep -q '^result=9$'  "$log" && correct=$((correct + 1))

# Cases = modules that both validated and returned their expected value.
checked=$validated
failed=0
[ "$code" -eq 0 ] || failed=1
[ "$validated" -eq 2 ] || failed=1
[ "$correct" -eq 2 ] || failed=1

printf 'GATE-COUNT checked=%s findings=%s\n' "$checked" "$failed"
if [ "$failed" -eq 0 ]; then
    printf 'wasm-smoke: PASS (%s modules validated, %s returned the expected value)\n' \
           "$validated" "$correct"
    exit 0
fi
printf 'wasm-smoke: FAIL (exit %s, %s validated, %s correct)\n' "$code" "$validated" "$correct"
exit 1
