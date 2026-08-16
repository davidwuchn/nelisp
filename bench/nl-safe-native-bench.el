;;; nl-safe-native-bench.el --- Doc 170 section 9 on the native path  -*- lexical-binding: t; -*-

;;; Commentary:

;; Section 9 budgets a checked shared borrow at 1.15x, and section 9 as
;; revised puts that budget on the AOT native path because on an
;; interpreter the shape alone -- acquire, body, release surviving a
;; non-local exit -- costs 2.69x before anything is checked.
;;
;; This runs inside the standalone reader.  It loads both sides of the
;; pair as `.neln' artifacts through the in-process loader and times
;; them, so the numbers come from the same native code a caller would
;; get, not from a host-Emacs stand-in or a C proof harness.
;;
;; The reader must have nl-safe loaded: the compiled units dispatch
;; `nl-safe--borrow-shared' and friends by name through the calln
;; dispatcher, which resolves against the runtime's own function table.
;;
;; Run by `make nl-safe-native-bench', which compiles the artifacts
;; first.  The generated prelude supplies the paths -- the reader has no
;; `getenv'.

;;; Code:

(defvar nl-safe-native-bench-dir nil
  "Directory holding the compiled pair; set by the generated prelude.")

(defvar nl-safe-native-bench-iterations 20000
  "Loop count passed into the compiled function.")

(defvar nl-safe-native-bench-repeats 5
  "Timed runs per side; the best is reported, to report the machine's
best case rather than its worst scheduling luck.")

(defvar nl-safe-native-bench-budget 1.15
  "The section 9 ratio for a checked shared borrow.")

(defun nl-safe-native-bench--ns (handle n repeats)
  "Return nanoseconds per iteration for HANDLE over N iterations."
  (let ((best nil)
        (round 0))
    (while (< round repeats)
      (let* ((start (float-time))
             (_ (nelisp-native-load-call handle (list n)))
             (elapsed (- (float-time) start))
             (ns (/ (* 1000000000.0 elapsed) n)))
        (when (or (null best) (< ns best))
          (setq best ns)))
      (setq round (1+ round)))
    best))

(defun nl-safe-native-bench-run ()
  "Measure the section 9 borrow budget on the native path."
  (let* ((n nl-safe-native-bench-iterations)
         (repeats nl-safe-native-bench-repeats)
         (checked-handle
          (nelisp-native-load-artifact
           (concat nl-safe-native-bench-dir "/nl-safe-native-bench-checked.neln")
           "nl-safe-native-bench-checked"))
         (plain-handle
          (nelisp-native-load-artifact
           (concat nl-safe-native-bench-dir "/nl-safe-native-bench-plain.neln")
           "nl-safe-native-bench-plain")))
    ;; Both sides must return the same value; a ratio between a working
    ;; borrow and a broken one measures nothing.
    (let ((cv (nelisp-native-load-call checked-handle (list 1)))
          (pv (nelisp-native-load-call plain-handle (list 1))))
      (unless (equal cv pv)
        (error "nl-safe-native-bench: sides disagree: checked=%S plain=%S" cv pv))
      (unless (equal cv 7)
        (error "nl-safe-native-bench: expected 7, got %S" cv)))
    (let* ((checked (nl-safe-native-bench--ns checked-handle n repeats))
           (plain (nl-safe-native-bench--ns plain-handle n repeats))
           (ratio (/ checked plain)))
      (princ "nl-safe native bench (Doc 170 section 9, in-process loader)\n")
      (princ (format "N=%d per call, best of %d\n\n" n repeats))
      (princ (format "%-24s %11s %11s %9s %s\n"
                     "pair" "checked" "plain" "ratio" "budget"))
      (princ "----------------------------------------------------------------------\n")
      (princ (format "%-24s %10.1fns %10.1fns %8.2fx <=%.2fx %s\n"
                     "borrow read (shared)" checked plain ratio
                     nl-safe-native-bench-budget
                     (if (<= ratio nl-safe-native-bench-budget) "PASS" "FAIL")))
      (princ "\nBoth sides are the same compiled shape with the same loop and\n")
      (princ "the same cell, differing only in the borrow bookkeeping, and\n")
      (princ "both are loaded and called the same way.\n")
      ratio)))

(provide 'nl-safe-native-bench)

;;; nl-safe-native-bench.el ends here
