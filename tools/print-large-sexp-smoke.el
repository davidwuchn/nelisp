;;; print-large-sexp-smoke.el --- prin1-to-string on a long spine and a deep nest -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Regression for the 2026-09-05 consumer report (nelisp-llm): serialising a
;; checkpoint plist of ~155k floats with `prin1-to-string' died with exit 139
;; on a d145e3c02 build, and its parallel suites died the same way.  Both were
;; the conservative-pin defect closed by e240485bb, not the printer -- but the
;; report also made the printer's own contract worth pinning on the binary
;; that ships: a long list is walked along its spine with a loop (one eval
;; level per NESTING level, never per element), a vector likewise, output is
;; not truncated by any fixed buffer, and the result reads back as the same
;; object.  A deep nest prints exactly, and `print-level' still caps it.
;;
;; Sizes are chosen to keep this under the smoke budget on the standalone
;; (measured 2026-09-05 on linux-x86_64: 10 000 integers 6.7 s, 1 000 levels
;; 10.5 s -- the deep case is quadratic in depth because every printer level
;; reads the special variables `print-length' / `print-level', and a special
;; lookup costs O(frame depth) in this runtime; 200 levels is ~0.4 s).  The
;; host-side ERT twin in test/nelisp-stdlib-test.el runs the 100k-element /
;; ~700 KB shape, which host Emacs prints in about a second.
;;
;; Run it through `make standalone-reader-print-large-sexp-smoke'.

;;; Code:

(defun nelisp-pls-fail (what got)
  (princ (format "[print-large-sexp-smoke] FAIL: %s -> %S\n" what got))
  (kill-emacs 1))

(defun nelisp-pls-nest (depth)
  "Return nil wrapped in DEPTH one-element lists."
  (let ((x nil) (i 0))
    (while (< i depth)
      (setq x (list x))
      (setq i (1+ i)))
    x))

;; 1. Long flat list: 10 000 six-digit integers -> "(" + 10000*6 digits +
;;    9999 spaces + ")" = 70 001 bytes.  Element k must sit at offset
;;    1 + 7k; every 500th one is checked by `substring', so a dropped
;;    separator, a truncated element or a fixed-size buffer shifts or cuts
;;    a later sample and fails.  The text is not re-read and not rebuilt
;;    with `mapconcat': on this binary `read-from-string' of a 70 KB list
;;    costs ~70 s and `mapconcat' over 10k items ~100 s (both measured
;;    2026-09-05; the former is a reader finding, the latter is the
;;    prelude's O(n^2) `concat' loop) -- neither is the printer's contract.
(let* ((n 10000)
       (lst (let ((l nil) (i n))
              (while (> i 0)
                (setq i (1- i))
                (setq l (cons (+ 100000 i) l)))
              l))
       (s (let ((print-length nil) (print-level nil))
            (prin1-to-string lst))))
  (unless (= (length s) (+ (* 7 n) 1))
    (nelisp-pls-fail "10k-int list printed length" (length s)))
  (unless (and (= (aref s 0) 40) (= (aref s (* 7 n)) 41))
    (nelisp-pls-fail "10k-int list delimiters" (substring s 0 10)))
  (let ((k 0))
    (while (< k n)
      (let ((at (+ 1 (* 7 k))))
        (unless (equal (substring s at (+ at 6)) (number-to-string (+ 100000 k)))
          (nelisp-pls-fail (format "10k-int list element %d at offset %d" k at)
                           (substring s at (+ at 6))))
        (unless (or (= k (1- n)) (= (aref s (+ at 6)) 32))
          (nelisp-pls-fail (format "10k-int list separator after element %d" k)
                           (aref s (+ at 6)))))
      (setq k (+ k 500)))))

;; 2. Vector of floats, the consumer's tensor shape: 300 distinct values,
;;    each must survive print -> read exactly (they are dyadic rationals).
(let* ((n 300)
       (v (make-vector n 0.0))
       (i 0))
  (while (< i n)
    (aset v i (* 0.0703125 (- (mod (* (1+ i) 11) 113) 56)))
    (setq i (1+ i)))
  (let ((s (let ((print-length nil) (print-level nil))
             (prin1-to-string (list :w (list 1 n) :data v)))))
    (unless (and (= (aref s 0) 40) (= (aref s (1- (length s))) 41))
      (nelisp-pls-fail "float plist delimiters" (substring s 0 20)))
    (let ((back (car (read-from-string s))))
      (unless (equal back (list :w (list 1 n) :data v))
        (nelisp-pls-fail "float vector does not read back equal"
                         (length s))))))

;; 3. Deep nest: 200 levels print as exactly 200 "(" + "nil" + 200 ")",
;;    and `print-level' 3 caps a deeper one the way Emacs does.
(let* ((depth 200)
       (deep (nelisp-pls-nest depth))
       (s (let ((print-length nil) (print-level nil))
            (prin1-to-string deep)))
       (expected (concat (make-string depth 40) "nil" (make-string depth 41))))
  (unless (equal s expected)
    (nelisp-pls-fail "200-deep nest" (length s)))
  (let ((capped (let ((print-level 3) (print-length nil))
                  (prin1-to-string (nelisp-pls-nest 4)))))
    (unless (equal capped "(((...)))")
      (nelisp-pls-fail "print-level 3 on a 4-deep nest" capped))))

(princ "[print-large-sexp-smoke] PASS: 10k-int list 70001 bytes exact, 300-float vector round-trips, 200-deep nest exact, print-level caps\n")

;;; print-large-sexp-smoke.el ends here
