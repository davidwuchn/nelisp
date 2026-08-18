#!/bin/sh
# bench-compare.sh --- compare two arms, and refuse to report a number
#                      that the machine invalidated.
#
# Every ratio this repository has been burned by was arithmetically
# correct:
#
#   * a 2.5x "regression" that was OneDrive and a crash-looping WSL
#     process competing for the CPU -- visible only because the
#     untouched baseline had also tripled;
#   * a 1.00x "parity" between two fixtures that had compiled to the
#     same program, so the benchmark was comparing one thing with
#     itself;
#   * a 0.02x result from a benchmark whose loop had been reshaped until
#     it passed, invalidating a day of numbers.
#
# So this harness does three things a bare `time' does not:
#
#   1. slope method -- each arm is run at n=0 and n=N and the difference
#      taken, so process start-up is not counted as work;
#   2. drift guard -- the base arm is run twice at n=N, and if those two
#      runs disagree by more than the limit the ratio is DISCARDED
#      rather than printed;
#   3. identity guard -- optional artifact digests must differ, because
#      two arms that are the same program produce a beautiful 1.00x.
#
# A discarded measurement is reported as an explicit `skip' with its
# reason, not as a pass and not as a failure: nothing was learned, and
# that is worth recording as its own outcome.
#
# Usage:
#   tools/ai/bench-compare.sh --name NAME \
#       --base      'CMD with %N% where the iteration count goes' \
#       --candidate 'CMD with %N%' \
#       [--iterations 3000] [--drift-limit 0.25] \
#       [--base-artifact PATH --candidate-artifact PATH] \
#       [--out target/ai/NAME-overhead.txt]

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cd "$root"

name=""
base=""
candidate=""
iterations=3000
drift_limit=0.25
base_artifact=""
candidate_artifact=""
out=""

die() { printf 'bench-compare.sh: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)               name="$2";               shift 2 ;;
        --base)               base="$2";               shift 2 ;;
        --candidate)          candidate="$2";          shift 2 ;;
        --iterations)         iterations="$2";         shift 2 ;;
        --drift-limit)        drift_limit="$2";        shift 2 ;;
        --base-artifact)      base_artifact="$2";      shift 2 ;;
        --candidate-artifact) candidate_artifact="$2"; shift 2 ;;
        --out)                out="$2";                shift 2 ;;
        -h|--help)            sed -n '2,40p' "$0"; exit 0 ;;
        *)                    die "unknown option: $1" ;;
    esac
done

[ -n "$name" ]      || die "--name is required"
[ -n "$base" ]      || die "--base is required"
[ -n "$candidate" ] || die "--candidate is required"
[ -n "$out" ]       || out="target/ai/$name-bench.txt"

mkdir -p "$(dirname "$out")" target/gates
gate() { "$here/gate-report.sh" "$@"; }

# Identity guard first: it costs nothing and invalidates everything.
if [ -n "$base_artifact" ] && [ -n "$candidate_artifact" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        a=$(sha256sum "$base_artifact" | cut -d' ' -f1)
        b=$(sha256sum "$candidate_artifact" | cut -d' ' -f1)
        if [ "$a" = "$b" ]; then
            printf 'IDENTICAL ARTIFACTS: %s and %s hash the same\n' \
                   "$base_artifact" "$candidate_artifact"
            gate --name "$name" --kind bench --ran 0 --failed 1 \
                 --reason "the two arms are the same program (identical sha256); any ratio would be meaningless" \
                 --command "bench-compare.sh --name $name"
            exit 1
        fi
    fi
fi

if [ "$base" = "$candidate" ]; then
    gate --name "$name" --kind bench --ran 0 --failed 1 \
         --reason "base and candidate commands are identical; any ratio would be meaningless" \
         --command "bench-compare.sh --name $name"
    exit 1
fi

# Milliseconds for one whole run of ARM at iteration count N.
timed() {
    cmd=$(printf '%s' "$1" | sed "s/%N%/$2/g")
    start=$(date +%s%N)
    eval "$cmd" > /dev/null 2>&1 || true
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

runs=0
base0=$(timed "$base" 0);            runs=$((runs + 1))
baseN=$(timed "$base" "$iterations"); runs=$((runs + 1))
cand0=$(timed "$candidate" 0);        runs=$((runs + 1))
candN=$(timed "$candidate" "$iterations"); runs=$((runs + 1))
baseN2=$(timed "$base" "$iterations"); runs=$((runs + 1))

verdict=$(awk -v b0="$base0" -v bn="$baseN" -v c0="$cand0" -v cn="$candN" \
              -v bn2="$baseN2" -v limit="$drift_limit" '
BEGIN {
  bc = bn - b0; cc = cn - c0;
  drift = (bn > 0) ? ((bn > bn2 ? bn - bn2 : bn2 - bn) / bn) : 1;
  # Either arm costing nothing measurable invalidates the ratio, and so
  # does a negative one: on a fast host the n=0 run can come out slower
  # than the n=N run through start-up noise alone, which produced a
  # cheerful "-2.00x" here before this line existed.  A ratio whose sign
  # is wrong is not a small error, it is a different quantity.
  if (bc <= 0 || cc <= 0) printf "discard cost %.2f", drift;
  else if (drift > limit) printf "discard drift %.2f", drift;
  else                    printf "valid %.2f %.2f", cc / bc, drift;
}')

set -- $verdict
state=$1
{
    printf '%s\n' "$name"
    printf 'iterations:  %s\n' "$iterations"
    printf 'base:        %s ms (%s at n=0, %s at n=N)\n' "$((baseN - base0))" "$base0" "$baseN"
    printf 'candidate:   %s ms (%s at n=0, %s at n=N)\n' "$((candN - cand0))" "$cand0" "$candN"
    printf 'base again:  %s ms\n' "$((baseN2 - base0))"
    printf 'base cmd:    %s\n' "$base"
    printf 'cand cmd:    %s\n' "$candidate"
    if [ "$state" = "valid" ]; then
        printf 'ratio:       %sx (drift %s, limit %s)\n' "$2" "$3" "$drift_limit"
    else
        printf 'ratio:       DISCARDED (%s %s, limit %s)\n' "$2" "$3" "$drift_limit"
    fi
} > "$out"

cat "$out"

if [ "$state" = "valid" ]; then
    gate --name "$name" --kind bench --ran "$runs" --passed "$runs" --failed 0 \
         --command "bench-compare.sh --name $name (ratio $2x)"
else
    # Nothing was learned.  That is a third outcome, and it gets said out
    # loud rather than rounded to either of the other two.
    gate --name "$name" --kind bench \
         --reason "measurement discarded: $2 $3 (limit $drift_limit); see $out" \
         --command "bench-compare.sh --name $name"
fi
