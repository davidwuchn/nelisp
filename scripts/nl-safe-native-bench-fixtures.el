;;; nl-safe-native-bench-fixtures.el --- section 9 pair as .neln  -*- lexical-binding: t; -*-

;;; Commentary:

;; Doc 170 section 9 budgets a checked shared borrow at 1.15x on the AOT
;; native path.  Two things had to change before that could be measured.
;;
;; The unit's extern set has to close over the runtime symbols, which
;; `nelisp-aot-compiler--dynamic-user-calls' does.  Both sides are
;; compiled that way, so the mode cancels out of the ratio.
;;
;; And the borrow helpers have to live IN the unit.  A call to an
;; ordinary elisp function reaches the reader through
;; `nelisp_apply_function', which dispatches a fixed if-chain over the
;; registered builtins -- `nl-safe--borrow-shared' is not one, so it goes
;; to stderr and returns.  Same-unit calls need no dispatcher at all.
;;
;; So the helpers below are nl-safe's, transcribed.  What that costs in
;; fidelity, stated rather than left to be discovered: the fast path is
;; identical -- the type check, the state read, the increment, the value
;; read, and the decrement on release.  What differs is the branch that
;; is never taken in a passing run.  nl-safe signals there; this returns
;; 0, because a compiled `signal' needs `nelisp_aot_signal' and the
;; reader has no such symbol, so a unit that signals cannot be loaded at
;; all.  The measured cost is the same either way: both are a `cellp'
;; test whose false arm is not entered.
;;
;; nl-safe also guards against borrowing a cell that is exclusively
;; borrowed.  That guard is a compare against the state already read,
;; and its false arm is likewise not entered here.
;;
;; Two more shapes the measurement depends on:
;;
;; The loop is INSIDE the compiled function.  The loader boxes integers,
;; not vectors, so a cell cannot be an argument -- and building one per
;; call would put an allocation in both sides and shrink the ratio
;; towards 1, flattering the borrow.  Built once, the timed region is
;; the borrow.
;;
;; The plain side is what `nl-with-borrow' expands to when checking is
;; disabled -- a `let' over the cell's value slot -- not a bare `aref'.
;; Section 9 is about the cost of the checking, not the cost of reaching
;; through a cell.

;;; Code:

(require 'nelisp-artifact)
(require 'nelisp-aot-compiler)

(defconst nl-safe-native-bench-helpers
  "(defun nl-safe-native-bench--cellp (c)
  (and (vectorp c) (= (length c) 3) (eq (aref c 0) 'nl--cell)))
(defun nl-safe-native-bench--acquire (c)
  (if (nl-safe-native-bench--cellp c)
      (let ((state (aref c 2)))
        (aset c 2 (1+ state))
        (aref c 1))
    0))
(defun nl-safe-native-bench--release (c)
  (aset c 2 (1- (aref c 2))))
"
  "nl-safe's shared-borrow fast path, transcribed for same-unit calls.")

(defconst nl-safe-native-bench-fixtures
  (list
   (list "nl-safe-native-bench-checked"
         (concat
          nl-safe-native-bench-helpers
          "(defun nl-safe-native-bench-checked (n)
  (let ((c (vector 'nl--cell (vector 7 8 9) 0)) (i 0) (acc 0))
    (while (< i n)
      (setq acc (let ((v (nl-safe-native-bench--acquire c)))
                  (unwind-protect (aref v 0)
                    (nl-safe-native-bench--release c))))
      (setq i (1+ i)))
    acc))"))
   (list "nl-safe-native-bench-plain"
         (concat
          nl-safe-native-bench-helpers
          "(defun nl-safe-native-bench-plain (n)
  (let ((c (vector 'nl--cell (vector 7 8 9) 0)) (i 0) (acc 0))
    (while (< i n)
      (setq acc (let ((v (aref c 1))) (aref v 0)))
      (setq i (1+ i)))
    acc))")))
  "(NAME SOURCE) for the two sides of the section 9 ratio.")

(defun nl-safe-native-bench-fixtures-build (dir)
  "Compile both sides into DIR, and report the extern set of each."
  (make-directory dir t)
  (dolist (entry nl-safe-native-bench-fixtures)
    (let* ((name (car entry))
           (el (expand-file-name (concat name ".el") dir))
           (neln (expand-file-name (concat name ".neln") dir))
           (nelisp-aot-compiler--dynamic-user-calls t))
      (with-temp-file el
        (insert (cadr entry) (format "\n(provide '%s)\n" name)))
      (nelisp-artifact-compile-file el neln nil nil nil nil nil 'neln)
      (let* ((native (plist-get (nelisp-artifact--read-payload neln) :native))
             (meta (car (seq-filter
                         (lambda (m) (equal (plist-get m :name) name))
                         (plist-get native :defuns)))))
        (message "[fixture] %-30s text=%s rt=%s externs=%S"
                 name (plist-get meta :size) (plist-get meta :rt-slot-count)
                 (plist-get native :extern-symbols))))))

(defun nl-safe-native-bench-fixtures-main ()
  "Entry point: build into the directory named by NELISP_ARTIFACT_DIR."
  (let ((dir (getenv "NELISP_ARTIFACT_DIR")))
    (unless dir
      (error "nl-safe-native-bench-fixtures: NELISP_ARTIFACT_DIR is unset"))
    (nl-safe-native-bench-fixtures-build dir)))

(provide 'nl-safe-native-bench-fixtures)

;;; nl-safe-native-bench-fixtures.el ends here
