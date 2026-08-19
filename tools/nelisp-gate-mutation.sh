#!/usr/bin/env bash
# Inject a known defect, require the named gate to go RED, restore.
#
# A gate is a claim that a class of defect cannot land.  The claim is only
# worth what it has been tested against, and testing a checker means giving
# it something to catch.  Three checks were green while seeing nothing on
# 2026-08-19; each would have been caught by one row of gate-mutations.txt.
set -u
cd "$(dirname "$0")/.." || exit 1
# "Text file busy" happens when the previous gate's subprocess still holds
# ./target/nelisp; it clears in well under a second, so one retry is enough
# and a second failure is a real build error.
rebuild_checked() {
  make standalone-reader >/dev/null 2>&1 && return 0
  sleep 2
  make standalone-reader >/dev/null 2>&1
}

rows=$(grep -v '^#' tools/gate-mutations.txt | grep -v '^[[:space:]]*$')
[ -z "$rows" ] && { echo "gate-mutation: FAIL (no mutations defined)"; exit 1; }
total=0; bad=0
while IFS='|' read -r gate file expr what; do
  [ -z "${gate:-}" ] && continue
  total=$((total+1))
  backup="$(mktemp)"
  cp "$file" "$backup" || { echo "gate-mutation: FAIL (cannot back up $file)"; exit 1; }
  sed -i "$expr" "$file"
  if cmp -s "$file" "$backup"; then
    echo "  $gate: SED MATCHED NOTHING -- the injection is stale ($what)"
    bad=$((bad+1))
    cp "$backup" "$file"; rm -f "$backup"; continue
  fi
  # A gate that needs the binary must see the mutated source, so rebuild --
  # and the rebuild MUST be checked.  The first run of this harness reported
  # emacs-parity as "stayed green": the rebuild had failed with "Text file
  # busy" (the binary was still held by the previous gate's subprocess), the
  # OLD binary was used, and the gate passed on code that no longer existed.
  # A harness that can be fooled by a stale artifact is measuring nothing --
  # which is the class it exists to catch.
  if [ "$gate" = "emacs-parity" ]; then
    if ! rebuild_checked; then
      echo "  $gate: HARNESS ERROR (rebuild with the injection failed; a stale binary would have read as PASS)"
      bad=$((bad+1))
      cp "$backup" "$file"; rm -f "$backup"; continue
    fi
  fi
  if make "$gate" >/dev/null 2>&1; then
    echo "  $gate: STAYED GREEN with a real defect in front of it ($what)"
    bad=$((bad+1))
  else
    echo "  $gate: went red as it should ($what)"
  fi
  cp "$backup" "$file"; rm -f "$backup"
  if [ "$gate" = "emacs-parity" ]; then rebuild_checked || true; fi
done <<< "$rows"
echo "GATE-COUNT checked=$total findings=$bad"
if [ "$bad" -gt 0 ]; then
  echo "gate-mutation: FAIL ($bad of $total gates did not catch their injected defect)"
  exit 1
fi
echo "gate-mutation: PASS ($total gates caught their injected defect)"
