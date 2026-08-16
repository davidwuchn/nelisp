;;; nl-safe-standalone-bench.el --- section 9 budgets on the real runtime  -*- lexical-binding: t; -*-

;;; Commentary:

;; `bench/nl-safe-bench.el' measures the Doc 170 section 9 budgets on
;; host Emacs and says, in its own header, that the gate is re-measured
;; on the standalone runtime.  Nothing did that, so the only numbers
;; anyone had were host numbers -- and on the host the budget is not
;; reachable by anything, nl-safe included:
;;
;;   (aref v 0)                        1.00x
;;   let + aref                        1.31x
;;   + unwind-protect                  1.48x   <- already over budget
;;   + one no-op call in the cleanup   2.11x
;;   + the acquire/release shape       2.69x
;;   section 9 budget                  1.15x
;;
;; None of that is nl-safe's code.  A borrow needs acquire, body, and a
;; release that survives a non-local exit, and that shape costs 2.69x
;; here before any checking happens.  So a host measurement can only
;; ever say "over budget", which makes it useless as a gate.
;;
;; This runs the same comparison on `target/nelisp', where the section 9
;; numbers were meant to be taken.
;;
;; Usage (the runtime is an ELF; run it where ELF runs):
;;   ./target/nelisp --load bench/nl-safe-standalone-bench.el

;;; Code:

(load "packages/nl-prelude/src/nl-prelude.el")
(load "packages/nl-safe/src/nl-safe.el")

(defvar nl-safe-bench--n 5000)

(defun nl-safe-bench--ns (thunk n)
  "Return nanoseconds per call for THUNK over N iterations, best of 3."
  (let ((best nil)
        (round 0))
    (while (< round 3)
      (let ((start (float-time))
            (i 0))
        (while (< i n)
          (funcall thunk)
          (setq i (1+ i)))
        (let ((ns (/ (* 1000000000.0 (- (float-time) start)) n)))
          (when (or (null best) (< ns best))
            (setq best ns))))
      (setq round (1+ round)))
    best))

(defun nl-safe-bench--report (label enabled baseline budget)
  (let ((ratio (/ enabled baseline)))
    (princ (format "%-30s %9.1f %9.1f %8.2fx <=%.2fx %s\n"
                   label enabled baseline ratio budget
                   (if (<= ratio budget) "OK" "FAIL")))))

(let* ((cell (nl-cell 7))
       (vec (vector 7))
       (plain (nl-safe-bench--ns (lambda () (aref vec 0)) nl-safe-bench--n))
       (borrow (nl-safe-bench--ns
                (lambda () (nl-with-borrow (v cell) v))
                nl-safe-bench--n)))
  (princ "nl-safe standalone bench (Doc 170 section 9)\n")
  (princ (format "N=%d, best of 3, target/nelisp\n\n" nl-safe-bench--n))
  (princ (format "%-30s %9s %9s %9s %s\n"
                 "pair" "enabled" "baseline" "ratio" "budget"))
  (princ (make-string 74 ?-))
  (princ "\n")
  (nl-safe-bench--report "borrow read (shared)" borrow plain 1.15))

0
