#!/bin/sh
# verify.sh --- prove the native-hotpath surface still behaves.
#
# Two gates, because two different things are being asserted and they
# are true on different sets of machines:
#
#   recipe-native-hotpath       compile + manifest.  Works everywhere.
#   recipe-native-hotpath-exec  running the compiled code.  The repo's
#                               own tests gate this on linux-x86_64
#                               (`skip-unless ...--linux-x86_64-p' in
#                               test/nelisp-artifact-native-exec-test.el),
#                               and on Windows the CLI exits 1.
#
# Splitting them keeps the compile half green where it is green instead
# of hiding it behind a platform failure — a gate that always fails is a
# gate everyone learns to ignore.
#
# Check 4 is a sensitivity control: it asks the manifest about a symbol
# that does not exist and requires a negative answer.  Without it,
# checks 2 and 3 would still "pass" if the grep pattern silently stopped
# matching anything.

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
    for name in recipe-native-hotpath recipe-native-hotpath-exec; do
        gate --name "$name" --kind smoke \
             --reason "no nelisp binary in target/; build one or set NELISP_BIN" \
             --command "recipes/native-hotpath/verify.sh"
    done
    exit 0
fi

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

printf 'native-hotpath: %s\n' "$NELISP"

cp "$here/skeleton/hot.el" "$work/hot.el"

# 1: compile
"$NELISP" compile-elisp-artifact --kind neln \
    --input "$work/hot.el" --output "$work/hot.neln" \
    > "$work/compile.log" 2>&1 || true
[ -s "$work/hot.neln" ] \
    && check ok "compiled to a .neln artifact" \
    || check no "no artifact produced: $(head -1 "$work/compile.log" 2>/dev/null)"

# 2-4: the manifest is the contract
"$NELISP" inspect-elisp-artifact "$work/hot.neln" > "$work/inspect.txt" 2>&1 || true

grep -q ':symbols ("hot-sum-to" "hot-checksum")' "$work/inspect.txt" \
    && check ok "both functions listed in the native section" \
    || check no "native :symbols does not list both functions"

grep -q ':name "hot-sum-to" :native t' "$work/inspect.txt" \
    && check ok "hot-sum-to reported as natively compiled" \
    || check no "hot-sum-to is not reported :native t -- it fell back"

grep -q ':name "hot-nonexistent" :native t' "$work/inspect.txt" \
    && check no "sensitivity control failed: the manifest reports a symbol that does not exist" \
    || check ok "sensitivity control: an absent symbol is not reported"

gate --name recipe-native-hotpath --kind smoke \
     --ran "$ran" --passed "$((ran - failed))" --failed "$failed" \
     --reason "$(printf '%s' "$note" | sed 's/^; //')" \
     --command "recipes/native-hotpath/verify.sh"

# Execution: a different claim, on a different set of machines.
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
    out=$("$NELISP" native-exec-elisp-artifact "$work/hot.neln" hot-sum-to 10 2>&1 || true)
    if printf '%s' "$out" | grep -q '55'; then
        printf '  ok   native-exec hot-sum-to 10 -> 55\n'
        gate --name recipe-native-hotpath-exec --kind smoke --ran 1 --passed 1 \
             --failed 0 --command "recipes/native-hotpath/verify.sh"
    else
        printf '  FAIL native-exec: %s\n' "$out"
        gate --name recipe-native-hotpath-exec --kind smoke --ran 1 --passed 0 \
             --failed 1 --reason "native-exec did not return 55: $out" \
             --command "recipes/native-hotpath/verify.sh"
    fi
else
    printf '  skip native-exec (%s %s)\n' "$(uname -s)" "$(uname -m)"
    gate --name recipe-native-hotpath-exec --kind smoke \
         --reason "native execution is linux-x86_64 only today; host is $(uname -s) $(uname -m)" \
         --command "recipes/native-hotpath/verify.sh"
fi
