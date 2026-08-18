#!/bin/sh
# measure.sh --- how much arena a request costs this service.
#
#   recipes/stdio-service/measure.sh [SMALL] [MIDDLE] [LARGE] [VARIANT]
#
# VARIANT names a file in skeleton/: `service' (plain) or
# `service-checked' (the request buffer under a borrow).  Running both
# is how to price adopting nl-safe in something that does real work,
# rather than pricing a borrow against a bare array read.
#
# The arena does not reclaim, so "how long can a resident service run"
# has a numeric answer, and this is how to get it: ask the service for
# its arena usage, send N requests, ask again.
#
# Three counts, not two.  A slope from two points assumes the growth is
# linear, and on one host it is not -- 110 and 210 requests both finish
# near the same total, so the per-request figure halves as N grows.  Two
# points would have reported whichever was measured first as if it were
# a rate.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

small=${1:-10}
middle=${2:-110}
large=${3:-210}
variant=${4:-service}

skeleton="recipes/stdio-service/skeleton/$variant.el"
[ -f "$skeleton" ] || { echo "measure.sh: no such variant: $skeleton" >&2; exit 2; }

NELISP=${NELISP_BIN:-}
if [ -z "$NELISP" ]; then
    for candidate in target/nelisp.exe target/nelisp; do
        [ -f "$candidate" ] && { NELISP="$candidate"; break; }
    done
fi
[ -n "$NELISP" ] || { echo "measure.sh: no nelisp binary; set NELISP_BIN" >&2; exit 2; }

mkdir -p target/ai

delta_for() {
    n=$1
    {
        printf '(stats)\n'
        i=0
        while [ "$i" -lt "$n" ]; do printf '(ping %s)\n' "$i"; i=$((i + 1)); done
        printf '(stats)\n(quit)\n'
    } | "$NELISP" --load "$skeleton" 2>/dev/null \
      | sed -n 's/^(used \([0-9]*\))$/\1/p' \
      | awk 'NR==1 { first = $1 } { last = $1 } END { print last - first }'
}

started=$(date +%s%N)
d_small=$(delta_for "$small")
d_middle=$(delta_for "$middle")
d_large=$(delta_for "$large")
elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))

slope_low=$(( (d_middle - d_small) / (middle - small) ))
slope_high=$(( (d_large - d_middle) / (large - middle) ))

out="target/ai/stdio-service-arena-$variant.txt"
{
    printf 'stdio-service arena growth\n'
    printf 'binary:        %s\n' "$NELISP"
    printf 'variant:       %s\n' "$variant"
    printf '%-6s requests: %s bytes\n' "$small" "$d_small"
    printf '%-6s requests: %s bytes\n' "$middle" "$d_middle"
    printf '%-6s requests: %s bytes\n' "$large" "$d_large"
    printf 'slope %s..%s:  %s bytes/request\n' "$small" "$middle" "$slope_low"
    printf 'slope %s..%s: %s bytes/request\n' "$middle" "$large" "$slope_high"
    # A high slope at or below zero is the clearest chunking signal of
    # all: the arena stopped growing between the two counts, so the
    # earlier figure was never a rate.
    if [ "$slope_high" -le 0 ] \
       || [ $(( slope_low * 4 )) -gt $(( slope_high * 5 )) ]; then
        printf 'shape:         CHUNKED -- the slopes disagree, so neither is a rate\n'
        printf '               use the largest total as an upper bound\n'
    else
        printf 'shape:         linear within these counts\n'
    fi
    printf 'wall clock:    %s ms for all three runs\n' "$elapsed_ms"
    printf 'note:          nothing is reclaimed; this is the budget for uptime\n'
} > "$out"

cat "$out"
