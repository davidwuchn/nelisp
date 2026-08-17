#!/bin/sh
# verify.sh --- prove the borrow discipline works, and measure what it costs
#               *here* instead of quoting someone else's number.
#
# The gate covers behaviour only:
#
#   1. a shared borrow reads the right value
#   2. an exclusive borrow taken while a shared one is live SIGNALS
#   3. the violation lands in the corpus the Phase 6 gate reads
#
# The overhead is measured by tools/ai/bench-compare.sh, which reports
# it under its own gate (bench-borrow-check) so that a number the
# machine invalidated cannot quietly become part of this recipe's
# verdict.  That harness runs each arm at n=0 and n=N and subtracts
# (the standalone runtime has no clock: `(current-time)' answers
# `(0 0 0 0)' and `(float-time)' answers nil), times the base arm twice
# to measure drift, and discards the ratio when the machine moved.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

ITERATIONS=${PROBE_ITERATIONS:-3000}
DRIFT_LIMIT=${PROBE_DRIFT_LIMIT:-0.25}

NELISP=${NELISP_BIN:-}
if [ -z "$NELISP" ]; then
    for candidate in target/nelisp.exe target/nelisp; do
        [ -f "$candidate" ] && { NELISP="$candidate"; break; }
    done
fi

gate() { "$root/tools/ai/gate-report.sh" "$@"; }

if [ -z "$NELISP" ]; then
    gate --name recipe-checked-resources --kind smoke \
         --reason "no nelisp binary in target/; build one or set NELISP_BIN" \
         --command "recipes/checked-resources/verify.sh"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p target/ai
rm -f target/ai/nl-safe-violations.log

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

probe() { PROBE_ARM=$1 PROBE_ITERATIONS=$2 "$NELISP" --load recipes/checked-resources/probe.el 2>&1; }

printf 'checked-resources: %s\n' "$NELISP"

probe behaviour 0 > "$work/behaviour.txt" || true

grep -q '^RESULT loaded=yes$' "$work/behaviour.txt" \
    && check ok "dependencies actually loaded (features present)" \
    || check no "nl-prelude / nl-safe are not loaded -- a load that found no file returns t here, so a wrong path is silent"

grep -q '^RESULT sum=24$' "$work/behaviour.txt" \
    && check ok "shared borrow reads the filled buffer (8 slots x 3)" \
    || check no "shared borrow did not return 24: $(grep '^RESULT sum=' "$work/behaviour.txt" || echo 'no result line')"

grep -q '^RESULT conflict=signalled$' "$work/behaviour.txt" \
    && check ok "exclusive borrow under a live shared borrow signals nl-borrow-error" \
    || check no "the conflicting borrow was NOT caught -- the checker is not doing anything"

violations=$(sed -n 's/^RESULT violations=//p' "$work/behaviour.txt" | head -1)
[ -n "${violations:-}" ] && [ "$violations" -ge 1 ] \
    && check ok "violation recorded in the corpus ($violations)" \
    || check no "no violation reached nl-safe-report's log"

gate --name recipe-checked-resources --kind smoke \
     --ran "$ran" --passed "$((ran - failed))" --failed "$failed" \
     --reason "$(printf '%s' "$note" | sed 's/^; //')" \
     --command "recipes/checked-resources/verify.sh"

# The cost, under its own gate.  Reported, never folded into the
# behaviour verdict above.
"$root/tools/ai/bench-compare.sh" \
    --name bench-borrow-check \
    --iterations "$ITERATIONS" \
    --drift-limit "$DRIFT_LIMIT" \
    --out target/ai/checked-resources-overhead.txt \
    --base "PROBE_ARM=plain PROBE_ITERATIONS=%N% $NELISP --load recipes/checked-resources/probe.el" \
    --candidate "PROBE_ARM=checked PROBE_ITERATIONS=%N% $NELISP --load recipes/checked-resources/probe.el"
