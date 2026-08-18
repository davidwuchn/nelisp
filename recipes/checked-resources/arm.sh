#!/bin/sh
# arm.sh --- run one arm of the probe with the parameters set as variables.
#
#   sh recipes/checked-resources/arm.sh behaviour 0
#   sh recipes/checked-resources/arm.sh checked 3000
#
# The parameters go in through a generated driver file rather than the
# environment, because `getenv' answers nil for everything on the Linux
# build.  Reading only the environment there meant every timed arm ran
# zero iterations while still looking like a successful measurement.
#
# Paths are relative to the repository root, which the runtime resolves
# against the working directory; an absolute POSIX path would be taken
# as drive-relative.

set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

arm=${1:-behaviour}
iterations=${2:-0}

NELISP=${NELISP_BIN:-}
if [ -z "$NELISP" ]; then
    for candidate in target/nelisp.exe target/nelisp; do
        [ -f "$candidate" ] && { NELISP="$candidate"; break; }
    done
fi
[ -n "$NELISP" ] || { echo "arm.sh: no nelisp binary" >&2; exit 2; }

mkdir -p target/ai
driver="target/ai/checked-arm.el"
cat > "$driver" <<EOF
(setq probe-arm "$arm")
(setq probe-iteration-count $iterations)
(load "recipes/checked-resources/probe.el" nil t)
EOF

exec "$NELISP" --load "$driver"
