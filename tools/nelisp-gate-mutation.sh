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

# `ert-full' rows run a real (deliberately red) `nelisp-ai.sh test', which
# writes a gate report into `NELISP_GATE_DIR' (default `target/gates').
# Left alone that would overwrite the tree's real `ert-full' report with a
# broken one on every `gate-mutation' run.  Scratch it into a throwaway
# directory instead; nothing else reads this one.
mutation_gate_dir="$(mktemp -d)"
trap 'rm -rf "$mutation_gate_dir"' EXIT

# Run the gate for the current row, on whatever content `$file' currently
# holds, capturing its combined output to `$2'.  `ert-full' is not a raw
# `make' target -- `nelisp-ai.sh test' owns it, wrapping ERT's own batch
# runner -- so it routes there instead of `make "$gate"'.  The corrupted-
# helper row (source: `src/nelisp-eval.el') is scoped to the one test file
# that calls the helper directly, via `NELISP_GATE_MUTATION_TEST_FILES' --
# see the comment on `test_files()' in `tools/ai/nelisp-ai.sh' for why the
# full suite is too slow to carry here.  The empty-glob row corrupts
# `test_files()' ITSELF (source: `tools/ai/nelisp-ai.sh'), so it must run
# UNSCOPED: scoping would bypass the very line the row exists to test.
run_gate() {
  local g="$1" f="$2" log="$3"
  if [ "$g" = "ert-full" ]; then
    if [ "$f" = "tools/ai/nelisp-ai.sh" ]; then
      NELISP_GATE_DIR="$mutation_gate_dir" \
        tools/ai/nelisp-ai.sh test >"$log" 2>&1
    else
      # Which test file a source-file mutation gets scoped to (speed
      # only -- see the block comment above): `src/nelisp-eval.el' is
      # exercised by `test/nelisp-eval-test.el' (the pre-existing row);
      # docs/design/185-cl-generic-subset.org's mutation rows target
      # `lisp/nelisp-cl-macros.el', exercised by
      # `test/nelisp-cl-generic-test.el'.  Any other file falls back to
      # the original single-file scope, unchanged.
      local scoped_test=test/nelisp-eval-test.el
      case "$f" in
        lisp/nelisp-cl-macros.el) scoped_test=test/nelisp-cl-generic-test.el ;;
        packages/nl-num/src/*.el) scoped_test=packages/nl-num/test/nl-num-test.el ;;
      esac
      NELISP_GATE_DIR="$mutation_gate_dir" \
        NELISP_GATE_MUTATION_TEST_FILES="$scoped_test" \
        tools/ai/nelisp-ai.sh test >"$log" 2>&1
    fi
  elif [ "$g" = "nelisp-thread-allocating-standalone-smoke" ]; then
    # The no-GC mutation can invalidate another worker's private frame before
    # it reaches the completion increment.  That missed-root manifestation is
    # an intentionally red hang, so bound the mutation run; the clean smoke
    # completes in well under one second on the same binary.
    timeout 30 make "$g" >"$log" 2>&1
  else
    make "$g" >"$log" 2>&1
  fi
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
  #
  # standalone-reader-buffer-smoke (Doc 188 P1, 2026-08-23) joins this list
  # for the identical reason: its own Makefile rule's prerequisite is
  # `$(if $(wildcard target/nelisp target/nelisp.exe),,standalone-reader)'
  # -- conditional on the binary's ABSENCE, not on the source being newer,
  # exactly like emacs-parity's own `standalone-reader-test' prerequisite.
  # Confirmed by hand while adding this row: with a leftover target/nelisp
  # already present, `make standalone-reader-buffer-smoke' on freshly
  # mutated source ran the OLD binary and reported PASS.
  # Doc 199's `nelisp-thread-standalone-smoke' has the same conditional
  # prerequisite and mutates native-unit source, so it must rebuild both the
  # injected and restored binary for the same reason.
  if [ "$gate" = "emacs-parity" ] || \
     [ "$gate" = "standalone-reader-buffer-smoke" ] || \
     [ "$gate" = "nelisp-thread-standalone-smoke" ] || \
     [ "$gate" = "nelisp-thread-allocating-standalone-smoke" ] || \
     [ "$gate" = "standalone-midform-gc-bounded" ]; then
    if ! rebuild_checked; then
      echo "  $gate: HARNESS ERROR (rebuild with the injection failed; a stale binary would have read as PASS)"
      bad=$((bad+1))
      cp "$backup" "$file"; rm -f "$backup"; continue
    fi
  fi
  gate_log="$(mktemp)"
  run_gate "$gate" "$file" "$gate_log"
  gate_rc=$?
  gate_ok=0; [ "$gate_rc" -eq 0 ] && gate_ok=1
  # Same precedence `tools/ai/nelisp-ai.sh cmd_gate' and `gate-selfcheck'
  # (tools/nelisp-gate-selfcheck.el) use for these two lines: a reasoned
  # `GATE-SKIP REASON' is checked before anything else, because a gate that
  # explains why it did not run does not also owe a verdict.  Before this,
  # a row whose gate legitimately skips (emacs-parity, outside its pinned
  # Emacs 30.x major) exited 0 with no defect ever exercised, and this
  # harness read that exit code the same as a real pass: "STAYED GREEN with
  # a real defect in front of it" -- a gate that never ran cannot have
  # stayed anything.  Measured via `NELISP_EMACS_PARITY_HOST_VERSION=29.4
  # make gate-mutation' (mocks a host outside 30.x; CI's ubuntu/29.4 lane
  # hits this for real): emacs-parity's row failed the whole harness on a
  # host where the gate cannot run at all, independent of any real defect.
  skip_after=$(grep -E '^GATE-SKIP ' "$gate_log" | tail -1 | sed 's/^GATE-SKIP //' || true)
  rm -f "$gate_log"
  if [ -n "$skip_after" ]; then
    # A row can only prove anything on a host where its gate actually runs;
    # a skip is "not provable here", not a pass -- UNLESS the injected
    # defect is what caused the skip, in which case the defect hid itself
    # behind a skip path instead of being caught, which is exactly the
    # "STAYED GREEN" failure this harness exists to catch, just via a
    # different exit than a plain 0.  Tell the two apart by asking the SAME
    # question of the clean tree: `gates.expected' documents three outcomes
    # (runnable / the predicate said no / the predicate could not be asked)
    # and only a skip that repeats UNCHANGED on clean code is "said no" --
    # a skip that appears only once the defect lands is the defect itself,
    # dressed as "could not be asked".
    cp "$backup" "$file"
    if [ "$gate" = "emacs-parity" ] || \
       [ "$gate" = "nelisp-thread-standalone-smoke" ] || \
       [ "$gate" = "nelisp-thread-allocating-standalone-smoke" ] || \
       [ "$gate" = "standalone-midform-gc-bounded" ]; then
      rebuild_checked || true
    fi
    baseline_log="$(mktemp)"
    run_gate "$gate" "$file" "$baseline_log"
    skip_before=$(grep -E '^GATE-SKIP ' "$baseline_log" | tail -1 | sed 's/^GATE-SKIP //' || true)
    rm -f "$baseline_log"
    if [ -n "$skip_before" ]; then
      echo "  $gate: SKIP (gate not runnable on this host: $skip_after)"
    else
      echo "  $gate: STAYED GREEN BY SKIPPING once the defect landed -- the clean tree does not skip for the same reason, so the injection itself trips the skip path and hides behind it ($what)"
      bad=$((bad+1))
    fi
    rm -f "$backup"
    continue
  fi
  if [ "$gate_ok" = 1 ]; then
    echo "  $gate: STAYED GREEN with a real defect in front of it ($what)"
    bad=$((bad+1))
  else
    echo "  $gate: went red as it should ($what)"
  fi
  cp "$backup" "$file"; rm -f "$backup"
  if [ "$gate" = "emacs-parity" ] || \
     [ "$gate" = "nelisp-thread-standalone-smoke" ] || \
     [ "$gate" = "nelisp-thread-allocating-standalone-smoke" ] || \
     [ "$gate" = "standalone-midform-gc-bounded" ]; then
    rebuild_checked || true
  fi
done <<< "$rows"
echo "GATE-COUNT checked=$total findings=$bad"
if [ "$bad" -gt 0 ]; then
  echo "gate-mutation: FAIL ($bad of $total gates did not catch their injected defect)"
  exit 1
fi
echo "gate-mutation: PASS ($total gates caught their injected defect)"
