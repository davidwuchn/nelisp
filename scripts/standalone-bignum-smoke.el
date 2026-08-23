;;; standalone-bignum-smoke.el --- Doc 190 Phase A bignum smoke -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run under the standalone runtime, not host Emacs:
;;
;;     nelisp --load scripts/standalone-bignum-smoke.el
;;
;; Doc 190 Phase A: the bignum box type (Sexp tag 13), reading (a literal
;; past most-positive-fixnum/most-negative-fixnum parses to a bignum
;; instead of wrapping), printing (prin1/read round-trip), comparison
;; (eql/=/</> across bignum-bignum and bignum-fixnum), integerp/numberp/
;; type-of, and the deliberate non-boundary: arithmetic (+/-/*) still
;; signals `overflow-error' on a bignum operand, unchanged from Doc 187 --
;; no promotion in this phase.  Every check is a plain value comparison
;; (no host-Emacs cross-check here; that lives in
;; `tools/nelisp-substrate-parity-corpus.el' entries 43/44 and in
;; `test/nelisp-bignum-test.el').
;;
;; Also runs a GC stress round (allocate many bignums across several
;; garbage-collect cycles, then re-verify every one still compares/prints
;; correctly) -- Doc 190's own GC-integration risk zone, complementing
;; (not replacing) `make standalone-reader-checked-soak'.
;;
;; The host-comparable half of this behavior (reading/printing/comparison
;; are all host-comparable) lives in `tools/nelisp-substrate-parity-
;; corpus.el' entries 43/44, run by `make substrate-parity-smoke'.

;;; Code:

(defvar bignum-smoke--n 0)
(defvar bignum-smoke--bad 0)

(defmacro bignum-smoke--check (label form)
  `(progn
     (setq bignum-smoke--n (1+ bignum-smoke--n))
     (condition-case e
         (unless ,form
           (setq bignum-smoke--bad (1+ bignum-smoke--bad))
           (princ (concat "FAIL " ,label "\n")))
       (error
        (setq bignum-smoke--bad (1+ bignum-smoke--bad))
        (princ (concat "FAIL " ,label " signalled " (prin1-to-string e) "\n"))))))

;; -- fencepost values, straddling most-positive-fixnum/most-negative-fixnum
;; exactly (Doc 190 §4's own fixnum-boundary corpus shape).
(bignum-smoke--check "N stays fixnum"
  (eq (type-of 2305843009213693951) 'integer))
(bignum-smoke--check "N not a bignum"
  (not (bignump 2305843009213693951)))
(bignum-smoke--check "N+1 promotes to bignum"
  (bignump 2305843009213693952))
(bignum-smoke--check "N+1 integerp"
  (integerp 2305843009213693952))
(bignum-smoke--check "N+1 numberp"
  (numberp 2305843009213693952))
(bignum-smoke--check "N+1 type-of integer"
  (eq (type-of 2305843009213693952) 'integer))
(bignum-smoke--check "-N-1 (most-negative-fixnum) stays fixnum"
  (not (bignump -2305843009213693952)))
(bignum-smoke--check "-N-2 promotes to bignum"
  (bignump -2305843009213693953))

;; -- printing: exact decimal, no wrap, matching what was written.
(bignum-smoke--check "N+1 prints exactly"
  (equal (prin1-to-string 2305843009213693952) "2305843009213693952"))
(bignum-smoke--check "huge positive prints exactly"
  (equal (prin1-to-string 123456789012345678901234567890)
         "123456789012345678901234567890"))
(bignum-smoke--check "huge negative prints exactly"
  (equal (prin1-to-string -123456789012345678901234567890)
         "-123456789012345678901234567890"))

;; -- prin1/read round-trip.
(let* ((b 123456789012345678901234567890)
       (b2 (car (read-from-string (prin1-to-string b)))))
  (bignum-smoke--check "round-trip bignump" (bignump b2))
  (bignum-smoke--check "round-trip equal" (equal b b2))
  (bignum-smoke--check "round-trip =" (= b b2))
  (bignum-smoke--check "round-trip eql" (eql b b2)))

;; -- comparison: bignum-bignum.
(bignum-smoke--check "big < big+1"
  (< 123456789012345678901234567890 123456789012345678901234567891))
(bignum-smoke--check "big+1 > big"
  (> 123456789012345678901234567891 123456789012345678901234567890))
(bignum-smoke--check "neg big < pos big"
  (< -123456789012345678901234567890 123456789012345678901234567890))
(bignum-smoke--check "big = itself via round-trip"
  (= 123456789012345678901234567890
     (car (read-from-string "123456789012345678901234567890"))))

;; -- comparison: bignum-fixnum, both directions, both signs.
(bignum-smoke--check "big > small fixnum"
  (> 2305843009213693952 5))
(bignum-smoke--check "small fixnum < big"
  (< 5 2305843009213693952))
(bignum-smoke--check "neg big < small fixnum"
  (< -2305843009213693953 5))
(bignum-smoke--check "small fixnum > neg big"
  (> 5 -2305843009213693953))

;; -- eq/eql/equal: eq is identity-only (two separately read bignums with
;; the same value must NOT be eq); eql/equal compare by value.
(let ((a (car (read-from-string "2305843009213693952")))
      (b (car (read-from-string "2305843009213693952"))))
  (bignum-smoke--check "eq same-value bignums is nil" (not (eq a b)))
  (bignum-smoke--check "eql same-value bignums is t" (eql a b))
  (bignum-smoke--check "equal same-value bignums is t" (equal a b))
  (bignum-smoke--check "= same-value bignums is t" (= a b)))

;; -- Doc 190 Phase A's own non-boundary: arithmetic (+/-/*) on a bignum
;; operand still signals `overflow-error', unchanged from Doc 187 -- no
;; promotion in this phase.
(bignum-smoke--check "+ on bignum operand signals overflow-error"
  (eq (condition-case nil (+ 2305843009213693952 1) (overflow-error 'ok))
      'ok))
(bignum-smoke--check "- on bignum operand signals overflow-error"
  (eq (condition-case nil (- 2305843009213693952 1) (overflow-error 'ok))
      'ok))
(bignum-smoke--check "* on bignum operand signals overflow-error"
  (eq (condition-case nil (* 2305843009213693952 1) (overflow-error 'ok))
      'ok))
(bignum-smoke--check "* on bignum operand (arg order) signals overflow-error"
  (eq (condition-case nil (* 1 2305843009213693952) (overflow-error 'ok))
      'ok))

;; -- fencepost controls: unaffected in-range arithmetic (no false
;; positives from the new bignum-detection checks).
(bignum-smoke--check "in-range + unaffected"
  (= (+ (1- most-positive-fixnum) 1) most-positive-fixnum))
(bignum-smoke--check "in-range * unaffected"
  (= (* most-positive-fixnum 1) most-positive-fixnum))
(bignum-smoke--check "expt overflow-check unaffected (Doc 187 precedent, unchanged)"
  (eq (condition-case nil (expt 2 61) (overflow-error 'ok)) 'ok))

;; -- GC stress round (Doc 190's own risk zone): allocate many distinct
;; bignums across several garbage-collect cycles, keep every one referenced,
;; then re-verify all of them still print/compare correctly.  Complements
;; (does not replace) `make standalone-reader-checked-soak'.
(let ((kept nil) (i 0))
  (while (< i 500)
    (push (car (read-from-string
                (concat "1" (make-string (+ 25 (mod i 20)) ?0) (number-to-string i))))
          kept)
    (setq i (1+ i))
    (when (= (mod i 100) 0) (garbage-collect)))
  (garbage-collect)
  (bignum-smoke--check "GC stress: every kept bignum still a bignum"
    (let ((ok t))
      (dolist (b kept) (unless (bignump b) (setq ok nil)))
      ok))
  (bignum-smoke--check "GC stress: every kept bignum still prints with a leading '1'"
    (let ((ok t))
      (dolist (b kept)
        (unless (= (aref (prin1-to-string b) 0) ?1) (setq ok nil)))
      ok))
  (bignum-smoke--check "GC stress: count preserved"
    (= (length kept) 500)))

(princ (format "BIGNUM-SMOKE cases=%d mismatches=%d\n"
               bignum-smoke--n bignum-smoke--bad))
nil
;;; standalone-bignum-smoke.el ends here
