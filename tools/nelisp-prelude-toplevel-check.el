;;; nelisp-prelude-toplevel-check.el --- the prelude's top level is definitions -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Adding an argument check to a ONE-LINE defun puts it after the closing
;; paren, where it becomes a top-level form of its own.  It then runs once
;; while the prelude loads, references a parameter that does not exist
;; there, and the load fails with `void-variable' -- pointing at the
;; parameter name, nowhere near the function it came from.
;;
;; That happened twice on 2026-08-20, and the second time cost four smokes
;; and a bisect.  The prelude's top level is definitions and declarations,
;; so anything that reads like a CALL to an ordinary function is the
;; mistake, and this says so with a line number.
;;
;; Deliberately narrow: it does not try to decide what a prelude may do, it
;; lists the heads that are legitimate at top level and flags the rest.  A
;; new legitimate head is one line here, and having to add it is the point
;; at which somebody looks.
;;
;; Run: make prelude-toplevel-check

;;; Code:

(defconst nelisp-prelude-toplevel--files
  '("scripts/nelisp-stdlib-prelude.el"))

(defconst nelisp-prelude-toplevel--allowed
  '(defun defmacro defvar defconst defalias defsubst defcustom defgroup
    unless when if progn provide require put setq setq-default fset
    dolist dotimes let let* while cond and or eval-when-compile
    eval-and-compile with-no-warnings declare-function ignore-errors
    condition-case add-to-list define-error
    ;; the prelude installs some names by calling its own registrars
    nelisp--error-register)
  "Heads that make sense as a top-level form here.")

(defvar nelisp-prelude-toplevel--eofs 0
  "How many files ended cleanly; reported so a zero cannot pass unnoticed.")

(defun nelisp-prelude-toplevel--note-eof ()
  "Record that a file ended at a form boundary."
  (setq nelisp-prelude-toplevel--eofs (1+ nelisp-prelude-toplevel--eofs)))

(defun nelisp-prelude-toplevel--note-unreadable (file start err cell)
  "Record that FILE stopped parsing at START with ERR, into CELL."
  (setcar cell (cons (list file (line-number-at-pos start) err) (car cell))))

(defun nelisp-prelude-toplevel-run ()
  (let ((bad nil) (forms 0) (bad-cell (list nil)))
    (dolist (file nelisp-prelude-toplevel--files)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((done nil))
          (while (not done)
            (let ((start (point)))
              (condition-case err
                  (let ((form (read (current-buffer))))
                    (setq forms (1+ forms))
                    (when (and (consp form)
                               (symbolp (car form))
                               (not (memq (car form) nelisp-prelude-toplevel--allowed)))
                      (push (list file (line-number-at-pos start) (car form)) bad)))
                ;; `end-of-file' is how the reader says "that was the last
                ;; form"; it is the loop's exit, not a fallback.  Named so
                ;; `make fallback-inventory' can tell the two apart.
                (end-of-file (nelisp-prelude-toplevel--note-eof) (setq done t))
                (error
                 (nelisp-prelude-toplevel--note-unreadable file start err bad-cell)
                 (setq bad (car bad-cell))
                 (setq done t))))))))
    (setq bad (append bad (car bad-cell)))
    (princ (format "prelude-toplevel: %d top-level forms, %d file(s) ended cleanly\n"
                   forms nelisp-prelude-toplevel--eofs))
    (dolist (b (nreverse bad))
      (princ (format "  %s:%d  top-level `%S'\n" (nth 0 b) (nth 1 b) (nth 2 b))))
    ;; `checked' counts FORMS: a reader that stopped at form 3 would
    ;; otherwise report a clean file.
    (princ (format "GATE-COUNT checked=%d findings=%d\n" forms (length bad)))
    (cond
     ((zerop forms)
      (princ "prelude-toplevel: FAIL (read nothing -- the file did not parse at all)\n")
      (kill-emacs 1))
     (bad
      (princ (format "prelude-toplevel: FAIL (%d top-level form(s) are calls, not definitions -- an argument check added to a ONE-LINE defun lands after its closing paren and becomes one of these; it then runs during the prelude load and fails with void-variable on the parameter name)\n"
                     (length bad)))
      (kill-emacs 1))
     (t (princ "prelude-toplevel: PASS\n")))))

(nelisp-prelude-toplevel-run)

;;; nelisp-prelude-toplevel-check.el ends here
