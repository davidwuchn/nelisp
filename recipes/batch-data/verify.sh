#!/bin/sh
# verify.sh --- prove the batch-data skeleton still works on this machine.
#
# The fixture is deliberately Japanese.  Multibyte text is where this
# runtime's file I/O actually differs from Emacs — `write-region' checks
# its own work by comparing a character count against a byte count and
# signals on every multibyte write *after writing the file correctly* —
# so an ASCII-only smoke would prove nothing about the case you have.
#
# Checks:
#   1. the output file exists, judged from the shell rather than from
#      inside the runtime (`file-exists-p' answers nil there for files
#      that demonstrably exist)
#   2. the row count is right
#   3. the aggregation keyed on a Japanese field is right
#   4. the Japanese key survives the round trip byte for byte

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
    gate --name recipe-batch-data --kind smoke \
         --reason "no nelisp binary in target/; build one or set NELISP_BIN" \
         --command "recipes/batch-data/verify.sh"
    exit 0
fi

# Work inside the repository, in paths relative to it, because the
# runtime resolves an absolute POSIX path against the current drive:
# a `/tmp/...' path from mktemp means %TEMP% to the shell and
# <drive>:\tmp to the runtime.  Combined with `load' returning t for a
# file it did not find, that produced a smoke which ran nothing and
# reported four failures with no explanation.
work=target/ai/batch-smoke
rm -rf "$work"
mkdir -p "$work"

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

printf 'batch-data: %s\n' "$NELISP"

cat > "$work/in.csv" <<'EOF'
事業場,点検日,結果
常石鉄工,2026-08-01,良
ハローズ手城店,2026-08-02,要注意
じゃんじゃか,2026-08-03,良
EOF

# Paths go in as variables, not environment: `getenv' answers nil for
# everything on the Linux build, including HOME, while it works on
# Windows.  A recipe that only ran on the platform it was written on is
# the reason this smoke now runs on both.
cat > "$work/run.el" <<EOF
(setq batch-input "$work/in.csv")
(setq batch-output "$work/out.txt")
(load "recipes/batch-data/skeleton/batch.el" nil t)
EOF
"$NELISP" --load "$work/run.el" > "$work/log.txt" 2>&1 || true

[ -s "$work/out.txt" ] \
    && check ok "output file written" \
    || check no "no output file: $(head -1 "$work/log.txt" 2>/dev/null)"

grep -q '^rows: 3$' "$work/out.txt" 2>/dev/null \
    && check ok "3 data rows counted (header dropped)" \
    || check no "row count wrong or missing"

grep -q '^良: 2$' "$work/out.txt" 2>/dev/null \
    && check ok "aggregation on a Japanese field" \
    || check no "expected '良: 2' in the report"

# Byte-for-byte: a mojibake round trip can still produce a plausible
# looking report, so compare the actual bytes of the key.
printf '要注意: 1\n' > "$work/expected-key.txt"
grep '^要注意' "$work/out.txt" > "$work/actual-key.txt" 2>/dev/null || true
cmp -s "$work/expected-key.txt" "$work/actual-key.txt" \
    && check ok "multibyte key survives read -> aggregate -> write" \
    || check no "multibyte key differs after the round trip"

gate --name recipe-batch-data --kind smoke \
     --ran "$ran" --passed "$((ran - failed))" --failed "$failed" \
     --reason "$(printf '%s' "$note" | sed 's/^; //')" \
     --command "recipes/batch-data/verify.sh"
