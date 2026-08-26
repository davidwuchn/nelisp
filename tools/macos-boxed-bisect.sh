#!/usr/bin/env bash
# Find which op in the `boxed' smoke faults, by running prefixes of it.
#
# `boxed' (tools/macos-selfhost-test.sh) exits 139 = SIGSEGV instead of
# 121 on macOS arm64.  It was added on 2026-06-02 as "macOS arm64 selfhost
# EMIT coverage" and its helper block is marked "(compile-only)" -- the
# program was proven to BUILD, never to RUN, and stage-d could not reach
# it for months because the vendor-clone step failed first.  So this is a
# first execution, not a regression.
#
# The program is one `run' of 20 statements.  A single exit code cannot
# say which one faulted, so build 20 variants: variant k runs statements
# 1..k and returns 42.  The first k that does not exit 42 is the culprit.
#
# Statements 1 and 2 (mmap the arena, set the bump pointer) are in every
# variant -- without them nothing can run at all.
#
#   tools/macos-boxed-bisect.sh              # build, sign, run  (macOS)
#   tools/macos-boxed-bisect.sh --emit-only  # build only        (any host)
set -u
cd "$(dirname "$0")/.." || exit 1
EMACS="${EMACS:-emacs}"
EMIT_ONLY=0
OUT_DIR="target/boxed-bisect"
HELPER_SET="original"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --emit-only) EMIT_ONLY=1; shift ;;
    --helpers) HELPER_SET="$2"; shift 2 ;;
    --emacs) EMACS="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "usage: $0 [--emit-only] [--helpers original|fixed] [--emacs EMACS] [--out-dir DIR]" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT_DIR"

# The helper block, verbatim from the `boxed' case in
# tools/macos-selfhost-test.sh.  Kept byte-identical on purpose: if these
# drift, the bisect stops describing the smoke it is supposed to explain.
HELPERS='
  (defun nl_alloc_bytes (size align) (atomic-fetch-add 34359738368 size))
  (defun nl_sexp_clone_into (src dst)
    (seq
      (ptr-write-u64 dst 0 (ptr-read-u64 src 0))
      (ptr-write-u64 dst 8 (ptr-read-u64 src 8))
      (ptr-write-u64 dst 16 (ptr-read-u64 src 16))
      (ptr-write-u64 dst 24 (ptr-read-u64 src 24))))
  (defun nl_alloc_consbox () (nl_alloc_bytes 24 8))
  (defun nl_alloc_cell (valptr)
    (let ((box (nl_alloc_bytes 16 8)))
      (seq (nl_sexp_clone_into valptr box) box)))
  (defun nl_cell_set_value (box valptr)
    (nl_sexp_clone_into valptr box))
  (defun nl_cell_get_value (cellptr out)
    (nl_sexp_clone_into (ptr-read-u64 (ptr-read-u64 cellptr 8) 0) out))
  (defun nl_val_clone_into (src dst)
    (if (= (logand src 1) 1)
        (ptr-write-u64 dst 0 src)
      (let ((box (nl_alloc_bytes 32 8)))
        (seq (nl_sexp_clone_into src box)
             (ptr-write-u64 dst 0 box)))))
  (defun nl_val_load (word scratch)
    (if (= (logand word 1) 0) word
      (seq (ptr-write-u64 scratch 0 word) scratch)))
  (defun nl_alloc_vector (cap)
    (let ((box (nl_alloc_bytes 32 8)))
      (seq
        (ptr-write-u64 box 8 (nl_alloc_bytes (* cap 8) 8))
        (ptr-write-u64 box 16 cap)
        box)))
  (defun nl_vector_set_slot (vec idx valptr)
    (nl_val_clone_into valptr (+ (ptr-read-u64 vec 8) (* idx 8))))
  (defun nl_vector_slot_ptr (sexpptr idx)
    (nl_val_load
     (ptr-read-u64 (+ (ptr-read-u64 (ptr-read-u64 sexpptr 8) 8) (* idx 8)) 0)
     (nl_alloc_bytes 32 8)))
  (defun nl_alloc_record (tagptr count)
    (let ((box (nl_alloc_bytes 64 8)))
      (seq
        (nl_sexp_clone_into tagptr box)
        (ptr-write-u64 box 40 (nl_alloc_bytes (* count 8) 8))
        (ptr-write-u64 box 48 count)
        box)))
  (defun nl_record_set_slot (rec idx valptr)
    (nl_val_clone_into valptr (+ (ptr-read-u64 rec 40) (* idx 8))))
  (defun nl_record_slot_ptr (sexpptr idx)
    (nl_val_load
     (ptr-read-u64 (+ (ptr-read-u64 (ptr-read-u64 sexpptr 8) 40) (* idx 8)) 0)
     (nl_alloc_bytes 32 8)))
'


# The same block with the cell helpers corrected to the Doc 147 Phase 1
# WORD layout.  Run the bisect once with each: `original' should stop at
# the first cell-value, `fixed' should run every prefix to 42.
HELPERS_FIXED='
  (defun nl_alloc_bytes (size align) (atomic-fetch-add 34359738368 size))
  (defun nl_sexp_clone_into (src dst)
    (seq
      (ptr-write-u64 dst 0 (ptr-read-u64 src 0))
      (ptr-write-u64 dst 8 (ptr-read-u64 src 8))
      (ptr-write-u64 dst 16 (ptr-read-u64 src 16))
      (ptr-write-u64 dst 24 (ptr-read-u64 src 24))))
  (defun nl_val_clone_into (src dst)
    (if (= (logand src 1) 1)
        (ptr-write-u64 dst 0 src)
      (let ((box (nl_alloc_bytes 32 8)))
        (seq (nl_sexp_clone_into src box)
             (ptr-write-u64 dst 0 box)))))
  (defun nl_val_load (word scratch)
    (if (= (logand word 1) 0) word
      (seq (ptr-write-u64 scratch 0 word) scratch)))
  (defun nl_alloc_consbox () (nl_alloc_bytes 24 8))
  (defun nl_alloc_cell (valptr)
    (let ((box (nl_alloc_bytes 16 8)))
      (seq (nl_val_clone_into valptr box) box)))
  (defun nl_cell_set_value (cellptr valptr)
    (nl_val_clone_into valptr (ptr-read-u64 cellptr 8)))
  (defun nl_cell_get_value (cellptr out)
    (nl_sexp_clone_into (ptr-read-u64 (ptr-read-u64 cellptr 8) 0) out))
  (defun nl_alloc_vector (cap)
    (let ((box (nl_alloc_bytes 32 8)))
      (seq
        (ptr-write-u64 box 8 (nl_alloc_bytes (* cap 8) 8))
        (ptr-write-u64 box 16 cap)
        box)))
  (defun nl_vector_set_slot (vec idx valptr)
    (nl_val_clone_into valptr (+ (ptr-read-u64 vec 8) (* idx 8))))
  (defun nl_vector_slot_ptr (sexpptr idx)
    (nl_val_load
     (ptr-read-u64 (+ (ptr-read-u64 (ptr-read-u64 sexpptr 8) 8) (* idx 8)) 0)
     (nl_alloc_bytes 32 8)))
  (defun nl_alloc_record (tagptr count)
    (let ((box (nl_alloc_bytes 64 8)))
      (seq
        (nl_sexp_clone_into tagptr box)
        (ptr-write-u64 box 40 (nl_alloc_bytes (* count 8) 8))
        (ptr-write-u64 box 48 count)
        box)))
  (defun nl_record_set_slot (rec idx valptr)
    (nl_val_clone_into valptr (+ (ptr-read-u64 rec 40) (* idx 8))))
  (defun nl_record_slot_ptr (sexpptr idx)
    (nl_val_load
     (ptr-read-u64 (+ (ptr-read-u64 (ptr-read-u64 sexpptr 8) 40) (* idx 8)) 0)
     (nl_alloc_bytes 32 8)))
'
case "$HELPER_SET" in
  original) ;;
  fixed)    HELPERS="$HELPERS_FIXED" ;;
  *) echo "--helpers must be original or fixed" >&2; exit 2 ;;
esac

# `run' statement by statement, in order.
STMTS=(
  '(syscall-direct 197 34359738368 1048576 3 4114 -1 0)'
  '(ptr-write-u64 34359738368 0 34359742464)'
  '(sexp-int-make 34359738432 5)'
  '(sexp-int-make 34359738496 17)'
  '(sexp-int-make 34359738560 19)'
  '(cell-make 34359738496 34359738624)'
  '(cell-value 34359738624 34359738688)'
  '(cell-set-value 34359738624 34359738560)'
  '(cell-value 34359738624 34359738752)'
  '(vector-make 2 34359738816)'
  '(vector-slot-set 34359738816 0 34359738496)'
  '(vector-slot-set 34359738816 1 34359738560)'
  '(vector-ref 34359738816 1 34359738880)'
  '(record-make 34359738432 2 34359738944)'
  '(record-slot-set 34359738944 0 34359738496)'
  '(record-slot-set 34359738944 1 34359738560)'
  '(record-slot-ref 34359738944 0 34359739008)'
  '(record-type-tag 34359738944 34359739072)'
  '(cons-make 34359738496 34359738560 34359739136)'
  '(vector-len 34359738816)'
  '(sexp-int-unwrap (vector-ref-ptr 34359738816 0))'
  '(record-slot-count 34359738944)'
  '(sexp-int-unwrap (record-slot-ref-ptr 34359738944 1))'
  '(sexp-payload-ptr-record 34359738944)'
  '(cons-cdr-raw 34359739136)'
)

n=${#STMTS[@]}
echo "--- boxed bisect: $n prefixes (helpers: $HELPER_SET) ---"
echo "    each variant runs statements 1..k and returns 42;"
echo "    the first k that does not exit 42 is where it breaks."
echo
first_bad=0
for ((k=2; k<=n; k++)); do
  body=""
  for ((i=0; i<k; i++)); do body="$body ${STMTS[$i]}"; done
  prog="(seq $HELPERS (defun run () (seq$body 42)) (exit (run)))"
  out="$OUT_DIR/boxed-$k"
  log="$OUT_DIR/boxed-$k.build.log"
  if ! "$EMACS" --batch -Q -L lisp -L src -L scripts -l nelisp-macos-build \
        --eval "(nelisp-macos-build-program (quote $prog) \"$out\")" >"$log" 2>&1; then
    printf '  %2d  %-52s BUILD FAILED\n' "$k" "${STMTS[$((k-1))]:0:52}"
    tail -3 "$log" | sed 's/^/        /'
    first_bad=$k; break
  fi
  if [ "$EMIT_ONLY" = 1 ]; then
    printf '  %2d  %-52s built\n' "$k" "${STMTS[$((k-1))]:0:52}"
    continue
  fi
  codesign -f -s - "$out" >/dev/null 2>&1 || { echo "  $k: codesign failed"; first_bad=$k; break; }
  chmod +x "$out"
  set +e; "$out" >/dev/null 2>&1; rc=$?; set -e
  if [ "$rc" = 42 ]; then
    printf '  %2d  %-52s ok\n' "$k" "${STMTS[$((k-1))]:0:52}"
  else
    printf '  %2d  %-52s EXIT %s%s\n' "$k" "${STMTS[$((k-1))]:0:52}" "$rc" \
      "$( [ "$rc" = 139 ] && echo '  <-- SIGSEGV' )"
    first_bad=$k; break
  fi
done

echo
if [ "$EMIT_ONLY" = 1 ]; then
  echo "emit-only: every prefix built (this host cannot run Mach-O aarch64)"
  exit 0
fi
if [ "$first_bad" = 0 ]; then
  echo "no prefix faulted -- the fault needs the full expression, not a prefix"
  exit 0
fi
echo "first faulting statement: #$first_bad  ${STMTS[$((first_bad-1))]}"
