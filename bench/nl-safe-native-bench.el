;;; nl-safe-native-bench.el --- section 9 budgets on the AOT native path  -*- lexical-binding: t; -*-

;;; Commentary:

;; Doc 170 section 9 (revised 2026-08-16) puts the 15% borrow budget on
;; the AOT native path and gives the interpreter path none, because on
;; an interpreter the shape alone -- acquire, body, release that
;; survives a non-local exit -- costs 2.69x before anything is checked.
;;
;; That revision is only honest if the native path can be measured, so
;; this measures it.  A checked borrow does compile through to native
;; x86_64: `nelisp-artifact-compile-file' with kind `neln' produces an
;; artifact whose manifest lists the function under :native :symbols.
;;
;; Two functions with the same body, one wrapped in `nl-with-borrow' and
;; one not, are compiled to separate .neln artifacts and executed
;; through `nelisp-artifact-native-exec'.  The ratio is the section 9
;; number for the path the budget now belongs to.
;;
;; Usage:
;;   emacs -Q --batch --eval '(setq load-prefer-newer t)' \
;;     -L lisp -L src -L bench $(package src dirs) \
;;     -l bench/nl-safe-native-bench.el -f nl-safe-native-bench-run

;;; Code:

(require 'nelisp-artifact)
(require 'nl-safe)

(defvar nl-safe-native-bench-iterations 20000
  "Calls per timed run.")

(defvar nl-safe-native-bench-repeats 3
  "Timed runs; the best is reported.")

(defvar nl-safe-native-bench--checked-source
  ";;; checked.el\n\
(defun nl-safe-native-bench--checked (c)\n\
  (nl-with-borrow (v c) (aref v 0)))\n\
(provide 'checked)\n"
  "A read through a checked borrow.")

(defvar nl-safe-native-bench--plain-source
  ";;; plain.el\n\
(defun nl-safe-native-bench--plain (c)\n\
  (let ((v (nl-safe--cell-value c))) (aref v 0)))\n\
(provide 'plain)\n"
  "The same read with no borrow bookkeeping.
This is what `nl-with-borrow' expands to when `nl-safe--enabled' is
nil, so the pair isolates the checking rather than the cell access.")

(defun nl-safe-native-bench--build (dir name source)
  "Compile SOURCE into a native artifact under DIR; return its path."
  (let ((el (expand-file-name (concat name ".el") dir))
        (neln (expand-file-name (concat name ".neln") dir)))
    (with-temp-file el (insert source))
    (nelisp-artifact-compile-file el neln nil nil nil nil nil 'neln)
    neln))

(defun nl-safe-native-bench--ns (artifact symbol arg)
  "Return nanoseconds per native call of SYMBOL in ARTIFACT."
  (let ((best nil)
        (round 0))
    (while (< round nl-safe-native-bench-repeats)
      (let ((start (float-time))
            (i 0))
        (while (< i nl-safe-native-bench-iterations)
          (nelisp-artifact-native-exec artifact symbol (list arg))
          (setq i (1+ i)))
        (let ((ns (/ (* 1e9 (- (float-time) start))
                     nl-safe-native-bench-iterations)))
          (when (or (null best) (< ns best))
            (setq best ns))))
      (setq round (1+ round)))
    best))

(defun nl-safe-native-bench-run ()
  "Measure the section 9 borrow budget on the AOT native path."
  (let ((dir (make-temp-file "nl-safe-native-bench-" t)))
    (unwind-protect
        (let* ((cell (nl-cell (vector 7)))
               (checked-artifact
                (nl-safe-native-bench--build
                 dir "checked" nl-safe-native-bench--checked-source))
               (plain-artifact
                (nl-safe-native-bench--build
                 dir "plain" nl-safe-native-bench--plain-source))
               (checked (nl-safe-native-bench--ns
                         checked-artifact "nl-safe-native-bench--checked" cell))
               (plain (nl-safe-native-bench--ns
                       plain-artifact "nl-safe-native-bench--plain" cell))
               (ratio (/ checked plain)))
          (princ "nl-safe native bench (Doc 170 section 9, AOT path)\n")
          (princ (format "N=%d, best of %d\n\n"
                         nl-safe-native-bench-iterations
                         nl-safe-native-bench-repeats))
          (princ (format "%-30s %11s %11s %9s %s\n"
                         "pair" "checked" "plain" "ratio" "budget"))
          (princ (make-string 76 ?-))
          (princ "\n")
          (princ (format "%-30s %11.1f %11.1f %8.2fx <=1.15x %s\n"
                         "borrow read (shared)" checked plain ratio
                         (if (<= ratio 1.15) "PASS" "FAIL")))
          (princ "\nBoth sides are executed through the same native-exec\n")
          (princ "path, and the plain side is exactly what the borrow macro\n")
          (princ "expands to with checking disabled, so the ratio isolates\n")
          (princ "the bookkeeping rather than the cell access.\n")
          ratio)
      (delete-directory dir t))))

(provide 'nl-safe-native-bench)

;;; nl-safe-native-bench.el ends here
