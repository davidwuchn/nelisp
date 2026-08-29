#!/usr/bin/env bash
# Precise root coverage for the mid-form collector.
#
# WHY THIS EXISTS.  `nl_gc_collect_recorded_mark_sweep' marks from two
# independent surfaces: the precise recorded-frame arms
# (`nl_gc_mark_recorded_frame' -- env / result / out / pool / src / cursor /
# bsym) and, in mode 0, a conservative native-stack scan
# (`nl_gc_conserv_maybe', SCAN_FLAG @268436464).  The shipped configuration
# runs both, and the scan is broad enough to keep alive anything a precise arm
# forgets.  That is good for production and terrible for verification: with the
# scan on, DELETING a precise root arm outright changes nothing observable, so
# no test over the shipped configuration can tell a sound root set from an
# unsound one.  Measured 2026-08-29: dropping the `result' arm entirely leaves
# the whole reader-smoke suite green.
#
# This gate removes the mask.  It runs a workload that fires several mid-form
# collections with the conservative scan disabled, so the precise arms are the
# only thing holding the executing form alive, and asserts the workload still
# computes the right answer.  Under that configuration the same `result'-arm
# deletion is an immediate SIGSEGV -- see the `precise-root-coverage' rows in
# tools/gate-mutations.txt.
#
# SCOPE, stated because it is narrow on purpose.  The precise surface is NOT
# sufficient for real programs: the same anvil module load that this gate's
# workload stands in for segfaults in under a second with the scan off, on a
# clean tree.  This gate therefore pins precise-root soundness for a bounded
# synthetic workload only.  It is not a claim that the conservative scan is
# removable.
#
# WHERE THE BOUNDARY ACTUALLY IS, measured 2026-08-29 while trying to widen
# this workload.  The failing construct is three lines, and it is a binding
# form collecting inside its own value expression:
#
#     (nelisp--debug-switch 28)
#     (defun f () (garbage-collect) 7)
#     (setq a (f))            ; rc=1;  (let ((x (f))) x) and let* likewise
#
# Bare `(f)', `(if (f) 1 2)', `(+ 1 (f))', `(list (f) 2)', `(progn (f) 1)',
# `(cons (f) nil)', a `while' body and a nested `(defun g () (f)) (g)' all
# pass.  So the gap under the scan is not general -- it is the binding forms.
# It is also not mid-form-collector-specific: the same three lines fail with
# the collector disarmed (switch 6), because the collection here is an
# explicit `garbage-collect', which is what `anvil-runtime-shell--compat-load'
# calls after every file it loads.
#
# The structural cause is that `nl_cons_car_ptr' MATERIALISES a fresh 32-byte
# box for an immediate car (lisp/nelisp-cc-jit-cons-car-ptr.el) and hands back
# a raw pointer to it; nothing roots that box, and its own comment counts ~302
# consumer sites.  The mechanism to fix it already exists and is already used
# by `nl_eval_inner_cons': `nl_root_mark' / `nl_root_reserve' /
# `nl_root_release' (lisp/nelisp-cc-rootstack.el).  Rooting `let''s `val_slot'
# alone was tried and measured: it does NOT make the three lines pass, so the
# hole is elsewhere in the same chain and was not shipped on a guess.
#
# Widening this gate means closing that, construct by construct, with each
# construct's three-line case added below as it goes green.
#
# It also pins the precondition for walking less of the reader parse pool than
# its whole capacity: with the pool slot walk suppressed (switch 26) the same
# workload must be byte-identical.  Measured 2026-08-29, the pool arm reaches
# nothing the other roots do not -- removing it entirely leaves every gate and
# the full anvil load green -- and this row is what would notice if that
# stopped being true.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NELISP="${NELISP:-$REPO_ROOT/target/nelisp}"
TMP_DIR="$(mktemp -d)"
CHECKED=0
FINDINGS=0

# Every case records its own finding, so the trap only has to cover an
# unexpected abort (a `set -e' death before the summary) -- otherwise it would
# double-count the deliberate `exit 1' below.
cleanup() {
  status=$?
  if [ "$status" -ne 0 ] && [ "$FINDINGS" -eq 0 ]; then
    FINDINGS=1
  fi
  printf 'GATE-COUNT checked=%s findings=%s\n' "$CHECKED" "$FINDINGS"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ ! -x "$NELISP" ]; then
  echo "[precise-root] SKIP: no runnable binary at $NELISP"
  exit 0
fi

# ITERS is sized so the alloc-debt gate (16 MiB) fires several times inside one
# top-level form; the assertion is on a literal that lives only in that form, so
# a collection that loses the form loses the literal too.
ITERS="${NELISP_PRECISE_ROOT_ITERS:-250000}"
EXPECT=$((ITERS * 7))

write_workload() {  # $1 = file, $2 = switch prologue
  cat > "$1" <<EOF
$2
(setq acc 0)
(setq n 0)
(while (< n $ITERS)
  (setq junk (list n n n n n n n n n n n n n n n n))
  (setq acc (+ acc (car '(7 8 9))))
  (setq n (+ n 1)))
(nelisp--write-stderr-line (concat "ACC=" (number-to-string acc)))
(nelisp--write-stderr-line
 (concat "FIRED=" (number-to-string (nth 7 (nelisp--debug-switch 0)))))
EOF
}

run_case() {  # $1 = label, $2 = switch prologue, $3 = min collections required
  local label="$1" prologue="$2" min_fired="$3"
  local src="$TMP_DIR/$label.el" err="$TMP_DIR/$label.err"
  write_workload "$src" "$prologue"
  CHECKED=$((CHECKED + 1))
  local rc=0
  "$NELISP" "$src" >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "precise_root_fail label=$label reason=nonzero-exit rc=$rc $(tr '\n' ' ' <"$err")" >&2
    FINDINGS=$((FINDINGS + 1))
    return 0
  fi
  local acc fired
  acc="$(sed -n 's/^ACC=//p' "$err")"
  fired="$(sed -n 's/^FIRED=//p' "$err")"
  if [ "$acc" != "$EXPECT" ]; then
    echo "precise_root_fail label=$label reason=wrong-answer got=$acc want=$EXPECT" >&2
    FINDINGS=$((FINDINGS + 1))
    return 0
  fi
  # A run that never collected proves nothing about root coverage.  This is the
  # "a gate that executed zero cases is not green" rule applied to the workload
  # itself rather than to the case count.
  if [ -z "$fired" ] || [ "$fired" -lt "$min_fired" ]; then
    echo "precise_root_fail label=$label reason=too-few-collections got=${fired:-none} want>=$min_fired" >&2
    FINDINGS=$((FINDINGS + 1))
    return 0
  fi
  echo "precise_root_result label=$label acc=$acc collections=$fired"
}

# 1. Baseline: the shipped configuration must agree with the expected answer,
#    so a failure in 2/3 cannot be blamed on the workload itself.
run_case shipped "" 1

# 2. The gate proper: precise arms only.  This is the case the `result'-arm
#    mutation turns red.
run_case no-conservative-scan "(nelisp--debug-switch 28)" 1

# 3. The pool arm carries no roots of its own, with the scan off so the scan
#    cannot be what makes that true.
run_case no-conservative-scan-no-pool-walk \
  "(nelisp--debug-switch 28)(nelisp--debug-switch 26)" 1

if [ "$FINDINGS" -ne 0 ]; then
  echo "precise-root-coverage: FAIL ($FINDINGS finding(s))"
  exit 1
fi
echo "precise-root-coverage: PASS ($CHECKED configurations, ${ITERS} iterations each)"
