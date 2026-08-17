#!/bin/sh
# verify.sh --- prove the stdio-service skeleton still works on this machine.
#
# Run this before writing any code of your own.  A recipe that cannot
# pass its own smoke here is telling you something about the runtime, the
# binary in target/, or the platform — and it is much cheaper to learn
# that now than from a half-written service.
#
# Checks, in order:
#   1. every request gets exactly one response line
#   2. arithmetic crosses the wire intact
#   3. the documented end-of-stream marker arrives
#   4. responses are flushed as they are produced, not buffered to exit
#
# Check 4 is the one that decides whether this shape is usable for an
# interactive host at all.  It is measured, not assumed: the producer
# holds the pipe open for four seconds and the response must already be
# on disk two seconds in.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

NELISP=${NELISP_BIN:-}
if [ -z "$NELISP" ]; then
    for candidate in target/nelisp.exe target/nelisp; do
        [ -f "$candidate" ] && { NELISP="$candidate"; break; }
    done
fi

gate() { "$root/tools/ai/gate-report.sh" "$@"; }

if [ -z "$NELISP" ]; then
    gate --name recipe-stdio-service --kind smoke \
         --reason "no nelisp binary in target/; build one or set NELISP_BIN" \
         --command "recipes/stdio-service/verify.sh"
    exit 0
fi

service="$here/skeleton/service.el"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ran=0
failed=0
note=""

check() {
    ran=$((ran + 1))
    if [ "$1" = "ok" ]; then
        printf '  ok   %s\n' "$2"
    else
        failed=$((failed + 1))
        note="$note; $2"
        printf '  FAIL %s\n' "$2"
    fi
}

printf 'stdio-service: %s\n' "$NELISP"

# 1-3: request/response round trip.
printf '(ping 1)\n(add 2 40)\n(bogus)\n(quit)\n' \
    | "$NELISP" --load "$service" > "$work/out.txt" 2> "$work/err.txt" || true

lines=$(grep -c . "$work/out.txt" || true)
# four responses plus the end-of-stream marker printed by `--load'
[ "$lines" -eq 5 ] && check ok "5 output lines (4 responses + marker)" \
                   || check no "expected 5 output lines, got $lines"

grep -q '^(sum 42)$' "$work/out.txt" \
    && check ok "(add 2 40) -> (sum 42)" \
    || check no "(add 2 40) did not answer (sum 42)"

grep -q '^service-eof$' "$work/out.txt" \
    && check ok "end-of-stream marker present" \
    || check no "no service-eof marker; --load semantics may have changed"

# 4: streaming.  The producer keeps the pipe open; the first response
# must land before the service is allowed to exit.
( printf '(ping 1)\n'; sleep 4; printf '(quit)\n' ) \
    | "$NELISP" --load "$service" > "$work/flush.txt" 2>&1 &
writer=$!
sleep 2
early=$(wc -c < "$work/flush.txt" | tr -d ' ')
wait "$writer" || true
[ "$early" -gt 0 ] \
    && check ok "response flushed while the pipe was still open ($early bytes at t=2s)" \
    || check no "nothing written at t=2s: output is buffered until exit, so this shape cannot drive an interactive host"

gate --name recipe-stdio-service --kind smoke \
     --ran "$ran" --passed "$((ran - failed))" --failed "$failed" \
     --reason "$(printf '%s' "$note" | sed 's/^; //')" \
     --command "recipes/stdio-service/verify.sh"
