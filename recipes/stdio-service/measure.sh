#!/bin/sh
# measure.sh --- how much arena a request costs this service.
#
#   recipes/stdio-service/measure.sh [SMALL] [MIDDLE] [LARGE]
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
    } | "$NELISP" --load recipes/stdio-service/skeleton/service.el 2>/dev/null \
      | sed -n 's/^(used \([0-9]*\))$/\1/p' \
      | awk 'NR==1 { first = $1 } { last = $1 } END { print last - first }'
}

d_small=$(delta_for "$small")
d_middle=$(delta_for "$middle")
d_large=$(delta_for "$large")

slope_low=$(( (d_middle - d_small) / (middle - small) ))
slope_high=$(( (d_large - d_middle) / (large - middle) ))

out=target/ai/stdio-service-arena.txt
{
    printf 'stdio-service arena growth\n'
    printf 'binary:        %s\n' "$NELISP"
    printf '%-6s requests: %s bytes\n' "$small" "$d_small"
    printf '%-6s requests: %s bytes\n' "$middle" "$d_middle"
    printf '%-6s requests: %s bytes\n' "$large" "$d_large"
    printf 'slope %s..%s:  %s bytes/request\n' "$small" "$middle" "$slope_low"
    printf 'slope %s..%s: %s bytes/request\n' "$middle" "$large" "$slope_high"
    if [ "$slope_low" -gt 0 ] && [ "$slope_high" -gt 0 ] \
       && [ $(( slope_low * 4 )) -gt $(( slope_high * 5 )) ]; then
        printf 'shape:         CHUNKED -- the slopes disagree, so neither is a rate\n'
        printf '               use the largest total as an upper bound\n'
    else
        printf 'shape:         linear within these counts\n'
    fi
    printf 'note:          nothing is reclaimed; this is the budget for uptime\n'
} > "$out"

cat "$out"
