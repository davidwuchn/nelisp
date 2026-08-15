;;; nl-ns-inventory.el --- CI namespace-boundary inventory via nl-ns -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Batch driver for `nl-ns': scan every .el under lisp/, src/, scripts/
;; and packages/*/src/, count the namespace findings per kind, and fail
;; when any kind EXCEEDS its checked-in baseline in
;; tools/ns-inventory-baseline.txt.
;;
;; Same ratchet as tools/nl-check-inventory.el: a count below the
;; baseline does not fail, it prints a notice so the baseline can be
;; lowered in the change that shrank the number.  The point is to stop
;; the numbers growing, not to demand a cleanup nobody scheduled.
;;
;; `ns-undeclared-dependency' is deliberately NOT counted here.  A tree
;; that has always relied on load order reports one finding per edge of
;; its real dependency graph, which is interesting to read once and
;; useless as a gate.  Pass a non-nil second argument to `nl-ns-check'
;; when you want to read it.
;;
;; Run from the repo root:
;;   emacs --batch -Q -L packages/nl-prelude/src -L packages/nl-ns/src \
;;     -l tools/nl-ns-inventory.el
;; or: make ns-inventory

;;; Code:

(require 'nl-ns)

(defconst nl-ns-inventory--baseline-file
  "tools/ns-inventory-baseline.txt")

(defconst nl-ns-inventory--kinds
  '(ns-collision ns-collision-divergent ns-prefix-violation
    ns-private-escape ns-unreadable)
  "Finding kinds this gate tracks, in report order.")

(defun nl-ns-inventory--baseline ()
  "Read the baseline as an alist of (KIND . COUNT), or nil when absent."
  (when (file-exists-p nl-ns-inventory--baseline-file)
    (with-temp-buffer
      (insert-file-contents nl-ns-inventory--baseline-file)
      (goto-char (point-min))
      (let ((rows nil))
        (while (not (eobp))
          (let* ((line (buffer-substring (line-beginning-position)
                                         (line-end-position)))
                 (space (string-match " " line)))
            (when (and space (> (length line) 0)
                       (not (eq (aref line 0) ?#)))
              (setq rows
                    (cons (cons (intern (substring line 0 space))
                                (string-to-number (substring line space)))
                          rows))))
          (forward-line 1))
        (nreverse rows)))))

(defun nl-ns-inventory--files ()
  "Return the .el files this inventory covers."
  (append (file-expand-wildcards "lisp/*.el")
          (file-expand-wildcards "src/*.el")
          (file-expand-wildcards "scripts/*.el")
          (file-expand-wildcards "packages/*/src/*.el")))

(defun nl-ns-inventory-run ()
  "Scan the tree, print the inventory, enforce the baseline."
  (let* ((files (nl-ns-inventory--files))
         (findings (nl-ns-check-files files))
         (baseline (nl-ns-inventory--baseline))
         (over nil))
    (princ (format "ns-inventory: %d files\n" (length files)))
    (dolist (kind nl-ns-inventory--kinds)
      (let* ((n (length (nl-ns-findings-of-kind findings kind)))
             (limit (cdr (assq kind baseline))))
        (princ (format "%6d  %-24s baseline=%s\n"
                       n kind (if limit limit "ABSENT")))
        (cond
         ((null limit) (setq over (cons kind over)))
         ((> n limit) (setq over (cons kind over)))
         ((< n limit)
          (princ (format "        ratchet available: %s is %d below baseline\n"
                         kind (- limit n)))))))
    (cond
     ((null baseline)
      (princ (format "ns-inventory: FAIL (no baseline file %s)\n"
                     nl-ns-inventory--baseline-file))
      (kill-emacs 1))
     (over
      (princ (format "ns-inventory: FAIL (%s over baseline -- a new cross-file collision, stray definition, or private-boundary reference; fix it or raise the baseline in the same commit)\n"
                     (mapconcat #'symbol-name (nreverse over) ", ")))
      (kill-emacs 1))
     (t (princ "ns-inventory: PASS\n")))))

(nl-ns-inventory-run)

;;; nl-ns-inventory.el ends here
