#!/bin/sh
# verify.sh --- prove the borrow discipline works, and measure what it costs
#               *here* instead of quoting someone else's number.
#
# The gate covers behaviour only:
#
#   1. a shared borrow reads the right value
#   2. an exclusive borrow taken while a shared one is live SIGNALS
#   3. the violation lands in the corpus the Phase 6 gate reads
#   4. the timed arm actually did work (a loop that ran zero times must
#      not look like a fast one)
#
# The overhead ratio is reported, never gated.  A ratio measured on a
# loaded machine is not a fact about the code: in this repository a
# "2.5x regression" turned out to be background load and a "1.00x
# parity" turned out to be one program compared with itself.  So the
# plain arm is timed twice and the drift between those runs is printed
# beside the ratio; when the drift is large the ratio is discarded here
# rather than written down and quoted later.
#
# Timing happens out here because the standalone runtime has no clock:
# `(current-time)' answers `(0 0 0 0)' and `(float-time)' answers nil.
# Each arm is therefore a whole process, and an empty run of the same
# arm is subtracted to remove start-up — the slope method already used
# for this repository's own benchmarks.

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

# Milliseconds for one whole arm, start-up included.
timed() {
    start=$(date +%s%N)
    probe "$1" "$2" > /dev/null 2>&1 || true
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

printf 'checked-resources: %s\n' "$NELISP"

probe behaviour 0 > "$work/behaviour.txt" || true

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

# Slope method: (arm at N) - (arm at 0) removes process start-up.
plain0=$(timed plain 0)
plainM=$(timed plain "$ITERATIONS")
checked0=$(timed checked 0)
checkedM=$(timed checked "$ITERATIONS")
plainM2=$(timed plain "$ITERATIONS")

[ "$plainM" -gt "$plain0" ] \
    && check ok "the timed arm did measurable work (${plain0}ms -> ${plainM}ms)" \
    || check no "the timed loop cost nothing; it did not run"

measurement=target/ai/checked-resources-overhead.txt
awk -v p0="$plain0" -v pm="$plainM" -v c0="$checked0" -v cm="$checkedM" \
    -v pm2="$plainM2" -v n="$ITERATIONS" -v limit="$DRIFT_LIMIT" \
    -v bin="$NELISP" '
BEGIN {
  pc = pm - p0; cc = cm - c0;
  drift = (pm > 0) ? ((pm > pm2 ? pm - pm2 : pm2 - pm) / pm) : 1;
  printf "checked-resources overhead\n";
  printf "binary:      %s\n", bin;
  printf "iterations:  %d\n", n;
  printf "plain:       %d ms (%d at n=0, %d at n=N)\n", pc, p0, pm;
  printf "checked:     %d ms (%d at n=0, %d at n=N)\n", cc, c0, cm;
  printf "plain again: %d ms\n", pm2 - p0;
  printf "drift:       %.2f (limit %.2f)\n", drift, limit;
  if (pc <= 0)          printf "ratio:       DISCARDED (plain arm cost nothing measurable)\n";
  else if (drift>limit) printf "ratio:       DISCARDED (machine moved under the measurement)\n";
  else                  printf "ratio:       %.2fx\n", cc / pc;
}' > "$measurement"

cat "$measurement"
printf 'measurement written to %s (reported, not gated)\n' "$measurement"

gate --name recipe-checked-resources --kind smoke \
     --ran "$ran" --passed "$((ran - failed))" --failed "$failed" \
     --reason "$(printf '%s' "$note" | sed 's/^; //')" \
     --command "recipes/checked-resources/verify.sh"
