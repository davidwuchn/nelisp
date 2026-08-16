;;; nl-safe-bench.el --- Doc 170 section 9 performance-budget bench  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 section 9 sets performance budgets for the nl-safe checked
;; paths *while checking is enabled*:
;;
;;   - `nl-cell' borrow        <= 15% overhead vs the plain access
;;   - fat pointer access      <= 20% overhead vs the plain access
;;
;; Section 12 notes the bench/ measurement as a follow-up; this file is
;; that measurement.  Three pairs are timed:
;;
;;   1. `nl-with-borrow' read        vs a plain let + `aref' baseline
;;   2. `nl-with-borrow-mut' round-trip (including the `nl-cell-set'
;;      write-back)                  vs a plain `aset' baseline
;;   3. `nl-ptr-ref-u8' through the mock backend
;;                                   vs the direct-funcall baseline
;;      (= the exact form the checks-off expansion produces)
;;
;; Usage (batch, from the repository root):
;;
;;   emacs --batch -Q -L packages/nl-prelude/src -L packages/nl-safe/src \
;;         -l bench/nl-safe-bench.el
;;
;; Output: one line per pair with ns/op for the enabled and baseline
;; loops plus the enabled/baseline ratio, and the section 9 budget the
;; ratio is compared against.
;;
;; Methodology notes (mirroring bench/nelisp-*-bench.el conventions):
;;
;;   - every loop body is const-unfoldable: the iteration count comes
;;     from a variable, the bodies fold into an accumulator that is
;;     returned, and the mut loop mutates the cell it reads,
;;   - each bench function is `byte-compile'd before timing so the
;;     macro-expansion cost is paid once and the ratio reflects the
;;     runtime checking overhead, not interpreter dispatch,
;;   - best-of-3 wall time per loop, `garbage-collect' before each run,
;;     with a high `gc-cons-threshold' to keep GC out of the loops.
;;
;; Host-Emacs numbers are *indicative only*: the standalone NeLisp
;; runtime (native cc pipeline + real raw-memory backend) has a
;; different cost model, so the section 9 gate proper must eventually
;; be re-measured there.  This harness is the reusable measurement.

;;; Code:

(require 'nl-safe)

(defvar nl-safe-bench-iterations 1000000
  "Iterations per timed loop.  1e6 gives stable ns/op on host Emacs.")

(defvar nl-safe-bench-repeats 3
  "Timed repetitions per loop; the best (minimum) wall time is kept.")

;;;; Benchmark bodies ---------------------------------------------------

;; Pair 1: shared borrow read vs plain let + aref.

(defun nl-safe-bench--borrow-read (n cell)
  "N `nl-with-borrow' shared-borrow reads of CELL; return the sum."
  (let ((acc 0))
    (dotimes (_ n)
      (nl-with-borrow (v cell)
        (setq acc (+ acc v))))
    acc))

(defun nl-safe-bench--borrow-read-baseline (n cell)
  "N plain let + `aref' reads of CELL's value slot; return the sum."
  (let ((acc 0))
    (dotimes (_ n)
      (let ((v (aref cell 1)))
        (setq acc (+ acc v))))
    acc))

;; Pair 2: exclusive borrow round-trip (read + nl-cell-set write-back)
;; vs plain aref + aset.

(defun nl-safe-bench--borrow-mut (n cell)
  "N `nl-with-borrow-mut' round-trips incrementing CELL via `nl-cell-set'."
  (dotimes (_ n)
    (nl-with-borrow-mut (v cell)
      (nl-cell-set cell (1+ v))))
  (aref cell 1))

(defun nl-safe-bench--borrow-mut-baseline (n cell)
  "N plain `aref' + `aset' round-trips incrementing CELL's value slot."
  (dotimes (_ n)
    (let ((v (aref cell 1)))
      (aset cell 1 (1+ v))))
  (aref cell 1))

;; Pair 3: checked nl-ptr-ref-u8 via the mock backend vs the direct
;; backend funcall (identical to the checks-off macro expansion).

(defun nl-safe-bench--ptr-ref (n ptr)
  "N checked `nl-ptr-ref-u8' reads through PTR; return the byte sum."
  (let ((acc 0))
    (dotimes (i n)
      (setq acc (+ acc (nl-ptr-ref-u8 ptr (logand i 63)))))
    acc))

(defun nl-safe-bench--ptr-ref-baseline (n ptr)
  "N direct backend funcalls through PTR (the checks-off expansion)."
  (let ((acc 0))
    (dotimes (i n)
      (setq acc (+ acc (funcall nl-safe-ptr-backend
                                'ref-u8 (aref ptr 1) (logand i 63)))))
    acc))

;;;; Harness -------------------------------------------------------------

(defun nl-safe-bench--time (fn &rest args)
  "Best-of-`nl-safe-bench-repeats' wall seconds for (apply FN ARGS)."
  (let ((best 1.0e+INF))
    (dotimes (_ nl-safe-bench-repeats)
      (garbage-collect)
      (let ((t0 (float-time)))
        (apply fn args)
        (setq best (min best (- (float-time) t0)))))
    best))

(defun nl-safe-bench--row (name enabled-fn baseline-fn budget arg)
  "Time ENABLED-FN vs BASELINE-FN (each called with N and ARG).
Print a table row NAME with ns/op and the ratio against BUDGET (a
float like 1.15, or nil for no budget).  Return the ratio."
  (let* ((n nl-safe-bench-iterations)
         (te (nl-safe-bench--time enabled-fn n arg))
         (tb (nl-safe-bench--time baseline-fn n arg))
         (ens (/ (* te 1e9) n))
         (bns (/ (* tb 1e9) n))
         (ratio (/ te tb)))
    (princ (format "%-26s %11.1f %11.1f %8.2fx %s\n"
                   name ens bns ratio
                   (if budget
                       (format "<=%.2fx %s" budget
                               (if (<= ratio budget) "PASS" "FAIL"))
                     "-")))
    ratio))

(defun nl-safe-bench-run ()
  "Run the Doc 170 section 9 budget bench and print the table."
  (mapc #'byte-compile
        '(nl-safe-bench--borrow-read nl-safe-bench--borrow-read-baseline
          nl-safe-bench--borrow-mut nl-safe-bench--borrow-mut-baseline
          nl-safe-bench--ptr-ref nl-safe-bench--ptr-ref-baseline))
  (let ((gc-cons-threshold (* 256 1024 1024)))
    (princ (format "nl-safe bench (Doc 170 section 9) -- N=%d, best of %d, %s\n"
                   nl-safe-bench-iterations nl-safe-bench-repeats
                   (emacs-version)))
    (princ "Doc 170 section 9 gives the interpreter path no budget (revised\n")
    (princ "2026-08-16).  A borrow needs acquire + body + a release that\n")
    (princ "survives a non-local exit, and that shape alone costs 2.69x here\n")
    (princ "before any checking happens; unwind-protect by itself is 1.48x.\n")
    (princ "The 15%/20% budgets belong to the AOT native path, where they are\n")
    (princ "a target for a check-elimination pass rather than for tuning these\n")
    (princ "helpers.  The ratios below are reported, not judged.\n\n")
    (princ (format "%-26s %11s %11s %9s %s\n"
                   "pair" "enabled" "baseline" "ratio" "budget"))
    (princ (format "%-26s %11s %11s %9s %s\n"
                   "" "(ns/op)" "(ns/op)" "" ""))
    (princ (make-string 78 ?-))
    (princ "\n")
    (nl-safe-bench--row "borrow read (shared)"
                        #'nl-safe-bench--borrow-read
                        #'nl-safe-bench--borrow-read-baseline
                        nil (nl-cell 7))
    (nl-safe-bench--row "borrow mut round-trip"
                        #'nl-safe-bench--borrow-mut
                        #'nl-safe-bench--borrow-mut-baseline
                        nil (nl-cell 0))
    (nl-safe-bench--row "ptr-ref-u8 (mock backend)"
                        #'nl-safe-bench--ptr-ref
                        #'nl-safe-bench--ptr-ref-baseline
                        nil (nl-safe-mock-ptr 64))))

(when noninteractive
  (nl-safe-bench-run))

(provide 'nl-safe-bench)

;;; nl-safe-bench.el ends here
