#!/usr/bin/env bash
# Run the gates CI runs, in CI's order, WITHOUT stopping at the first failure.
#
# Why this exists: CI is fail-fast, and a full round on this repo costs about
# an hour and a half.  When a change breaks N independent gates -- which is the
# normal case for ratchet drift, where an ns-inventory count, a fallback pin
# and a smoke's preload can all move together -- fail-fast turns that into N
# rounds, discovered one at a time.  Running the same list locally with the
# failures COLLECTED instead of fatal turns it back into one pass.  The Stage 5
# landing used exactly this shape and went green on its first CI round.
#
# This does not replace CI.  It front-runs the cheap, deterministic part of it.
#
# Usage:
#   tools/ai/preflight.sh            # the fast tier (inventories + parity)
#   tools/ai/preflight.sh --full     # everything below, including the slow tiers
#   tools/ai/preflight.sh --list     # print the tiers and exit
#
# Exit status is the number of failing gates (0 = all clear), capped at 125.
set -u

FULL=0
case "${1:-}" in
  --full) FULL=1 ;;
  --list) sed -n '/^FAST_GATES=/,/^)/p;/^SLOW_GATES=/,/^)/p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

# Ordered to match .github/workflows/ci.yml's own Linux lane, so the first
# thing that fails here is the first thing that would fail there.
FAST_GATES=(
  "compile|make compile"
  "unsafe-inventory|make unsafe-inventory"
  "ns-inventory|make ns-inventory"
  "parens-check|make parens-check"
  "reader-surface-audit|make reader-surface-audit"
  "pkg-graph|make pkg-graph"
  "pkg-load-lists|make pkg-load-lists"
  "doc-claims|make doc-claims"
  "bench-aot-tco|make bench-aot-tco"
  "emacs-parity|make emacs-parity"
)
SLOW_GATES=(
  "checked-alloc|make standalone-reader-checked"
  "shadow-smoke|make standalone-reader-shadow-smoke"
  "binary-size-ratchet|make binary-size-ratchet"
  "check-tier|bash tools/ai/nelisp-ai.sh check"
  "extras|bash tools/ai/nelisp-ai.sh extras"
  "perf|bash tools/ai/nelisp-ai.sh perf"
  "ert-full|bash tools/ai/nelisp-ai.sh test"
)

OUT=${PREFLIGHT_LOGDIR:-target/preflight}
mkdir -p "$OUT"
declare -a NAMES STATUS COUNTS

run_gate() {
  local name=${1%%|*} cmd=${1#*|}
  printf '\n########## %s ##########\n%s\n' "$name" "$cmd"
  local log="$OUT/$name.log"
  # Deliberately NOT `set -e' and deliberately not short-circuiting: the whole
  # point is to learn about every failure in one pass.
  eval "$cmd" > "$log" 2>&1
  local rc=$?
  local gc
  gc=$(grep -aoE 'GATE-COUNT checked=[0-9]+ findings=[0-9]+' "$log" | tail -1)
  [ -z "$gc" ] && gc="(no GATE-COUNT line)"
  NAMES+=("$name"); COUNTS+=("$gc")
  if [ $rc -eq 0 ]; then STATUS+=("pass"); else STATUS+=("FAIL rc=$rc"); fi
  printf 'rc=%s  %s\n' "$rc" "$gc"
  # A gate that reports checked=0 crashed rather than ran; that distinction has
  # been mistaken for a slowdown before, so call it out here.
  case "$gc" in *"checked=0 "*) printf '  !! checked=0 -- this gate DIED, it did not merely regress\n';; esac
}

for g in "${FAST_GATES[@]}"; do run_gate "$g"; done
[ $FULL -eq 1 ] && for g in "${SLOW_GATES[@]}"; do run_gate "$g"; done

fails=0
printf '\n================ PREFLIGHT SUMMARY ================\n'
for i in "${!NAMES[@]}"; do
  printf '%-24s %-12s %s\n' "${NAMES[$i]}" "${STATUS[$i]}" "${COUNTS[$i]}"
  case "${STATUS[$i]}" in FAIL*) fails=$((fails+1));; esac
done
printf '==================================================\n'
printf 'logs: %s\n' "$OUT"
if [ $fails -eq 0 ]; then
  printf 'PREFLIGHT: all %d gate(s) clear\n' "${#NAMES[@]}"
else
  printf 'PREFLIGHT: %d of %d gate(s) FAILED -- fix all of them before pushing\n' \
    "$fails" "${#NAMES[@]}"
fi
[ $fails -gt 125 ] && fails=125
exit $fails
