;;; nl-safe-native-bench-fixtures.el --- section 9 pair as .neln  -*- lexical-binding: t; -*-

;;; Commentary:

;; Doc 170 section 9 budgets a checked shared borrow at 1.15x on the AOT
;; native path.  That could not be measured until now: the borrow's
;; helpers are ordinary elisp functions, so the compiled unit carried
;; relocations naming them and nothing could resolve those in-process.
;;
;; `nelisp-aot-compiler--dynamic-user-calls' routes such calls through
;; the calln dispatcher instead, which closes the unit's extern set over
;; the runtime symbols, and `lisp/nelisp-native-load.el' loads it.  Both
;; sides of the pair are compiled that way, so the mode is common to
;; them and cancels out of the ratio.
;;
;; Two shapes the measurement depends on:
;;
;; The loop is INSIDE the compiled function.  The loader boxes integers,
;; not vectors, so a cell cannot be an argument -- and building one per
;; call would put an allocation in both sides and shrink the ratio
;; towards 1, flattering the borrow.  Built once, the timed region is the
;; borrow.
;;
;; The plain side is what `nl-with-borrow' expands to when checking is
;; disabled, not a hand-written `aref'.  Section 9 is about the cost of
;; the checking, not the cost of reaching through a cell.

;;; Code:

(require 'nelisp-artifact)
(require 'nelisp-aot-compiler)
;; The macro has to be defined in THIS process, not merely required by
;; the file being compiled: otherwise `nl-with-borrow' is never expanded
;; and the unit ends up with externs named `nl-with-borrow' and `v'.
(require 'nl-prelude)
(require 'nl-safe)

(defconst nl-safe-native-bench-fixtures
  '(("nl-safe-native-bench-checked"
     "(defun nl-safe-native-bench-checked (n)
  (let ((c (nl-cell (vector 7 8 9))) (i 0) (acc 0))
    (while (< i n)
      (setq acc (nl-with-borrow (v c) (aref v 0)))
      (setq i (1+ i)))
    acc))")
    ("nl-safe-native-bench-plain"
     "(defun nl-safe-native-bench-plain (n)
  (let ((c (nl-cell (vector 7 8 9))) (i 0) (acc 0))
    (while (< i n)
      (setq acc (let ((v (nl-safe--cell-value c))) (aref v 0)))
      (setq i (1+ i)))
    acc))"))
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
        (insert "(require 'nl-prelude)\n(require 'nl-safe)\n"
                (cadr entry) (format "\n(provide '%s)\n" name)))
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
