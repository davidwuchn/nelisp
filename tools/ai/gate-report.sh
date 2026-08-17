#!/bin/sh
# gate-report.sh --- emit one gate report from a shell gate.
#
# Shell smokes are the gates most likely to rot silently: they exit 0
# when the binary under test is missing, when a loop body never runs, or
# when the platform check at the top returns early.  Reporting a count
# makes all three visible.
#
# Usage:
#   tools/ai/gate-report.sh --name standalone-reader --kind smoke \
#       --ran 20 --passed 20 --failed 0 [--skipped 0] \
#       [--reason "linux-only binary, host is windows"] \
#       [--command "make standalone-reader-test"] [--duration-ms 4200]
#
# --reason on a gate with no failures declares an explicit skip, which is
# reported as "skip" rather than "pass".  A gate that cannot run must say
# so out loud; a gate that always fails gets ignored by everyone, which
# is how three standalone smokes in this repository became decorative.
#
# Exit code: 0 for pass/skip, 1 for fail.  The report is written whatever
# the outcome, because the aggregator treats a missing report as failure.

set -eu

name=""
kind="smoke"
ran=0
passed=0
failed=0
skipped=0
reason=""
command_line=""
duration_ms=0
status=""

die() { printf 'gate-report.sh: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)        name="$2";          shift 2 ;;
        --kind)        kind="$2";          shift 2 ;;
        --ran)         ran="$2";           shift 2 ;;
        --passed)      passed="$2";        shift 2 ;;
        --failed)      failed="$2";        shift 2 ;;
        --skipped)     skipped="$2";       shift 2 ;;
        --reason)      reason="$2";        shift 2 ;;
        --command)     command_line="$2";  shift 2 ;;
        --duration-ms) duration_ms="$2";   shift 2 ;;
        --status)      status="$2";        shift 2 ;;
        -h|--help)     sed -n '2,25p' "$0"; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
done

[ -n "$name" ] || die "--name is required"

# Same rule as `nelisp-gate-derive-status': zero executed cases is a
# failure, an explicit reason with no failures is a skip.
if [ -z "$status" ]; then
    if [ -n "$reason" ] && [ "$failed" -eq 0 ]; then
        status="skip"
    elif [ "$failed" -gt 0 ]; then
        status="fail"
    elif [ "$ran" -eq 0 ]; then
        status="fail"
        reason="gate executed 0 cases"
    else
        status="pass"
    fi
fi

json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr '\n\r\t' '   '
}

dir="${NELISP_GATE_DIR:-target/gates}"
mkdir -p "$dir"
file="$dir/$name.json"

cat > "$file" <<EOF
{
  "schema": "nelisp-gate/1",
  "name": "$(json_escape "$name")",
  "kind": "$(json_escape "$kind")",
  "status": "$(json_escape "$status")",
  "ran": $ran,
  "passed": $passed,
  "failed": $failed,
  "skipped": $skipped,
  "reason": "$(json_escape "$reason")",
  "command": "$(json_escape "$command_line")",
  "duration_ms": $duration_ms,
  "finished": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "host": "$(hostname)"
}
EOF

printf 'gate report: %s (%s, ran %s, failed %s)\n' "$file" "$status" "$ran" "$failed"

case "$status" in
    pass|skip) exit 0 ;;
    *)         exit 1 ;;
esac
