#!/bin/sh
# arm.sh --- send N ping requests to one service variant.
#
#   sh recipes/stdio-service/arm.sh service 200
#   sh recipes/stdio-service/arm.sh service-checked 200
#
# Written for tools/ai/bench-compare.sh, which times each arm at n=0 and
# n=N and subtracts, so the price of adopting nl-safe here is measured
# against the same service doing the same work without it.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

variant=${1:-service}
n=${2:-0}
skeleton="recipes/stdio-service/skeleton/$variant.el"
[ -f "$skeleton" ] || { echo "arm.sh: no such variant: $skeleton" >&2; exit 2; }

NELISP=${NELISP_BIN:-}
if [ -z "$NELISP" ]; then
    for candidate in target/nelisp.exe target/nelisp; do
        [ -f "$candidate" ] && { NELISP="$candidate"; break; }
    done
fi
[ -n "$NELISP" ] || { echo "arm.sh: no nelisp binary" >&2; exit 2; }

{
    i=0
    while [ "$i" -lt "$n" ]; do printf '(ping %s)\n' "$i"; i=$((i + 1)); done
    printf '(quit)\n'
} | "$NELISP" --load "$skeleton" > /dev/null 2>&1
