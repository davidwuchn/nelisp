;;; nl-check-inventory.el --- CI unsafe-surface inventory via nl-check -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 section 4.3: "have nl-check report the unsafe surface and
;; track its growth in CI".  Batch driver: scan every .el under lisp/
;; and scripts/ with `nl-check-file', count `unsafe-call' findings
;; (unsafe primitives called outside an `nl-unsafe' block; quoted
;; forms -- i.e. the AOT grammar data -- are not scanned by design),
;; and fail when the total EXCEEDS the checked-in baseline in
;; tools/unsafe-inventory-baseline.txt.
;;
;; A total below the baseline does not fail; it prints a ratchet
;; notice so the baseline can be lowered in the same change that
;; shrank the surface.
;;
;; Run from the repo root:
;;   emacs --batch -Q -L packages/nl-prelude/src -L packages/nl-safe/src \
;;     -L packages/nl-check/src -l tools/nl-check-inventory.el
;; or: make unsafe-inventory

;;; Code:

(require 'nl-check)

(defconst nl-check-inventory--baseline-file
  "tools/unsafe-inventory-baseline.txt")

(defun nl-check-inventory--baseline ()
  "Read the integer baseline, or nil when the file is absent."
  (when (file-exists-p nl-check-inventory--baseline-file)
    (with-temp-buffer
      (insert-file-contents nl-check-inventory--baseline-file)
      (string-to-number (buffer-string)))))

(defun nl-check-inventory-run ()
  "Scan lisp/ and scripts/, print the inventory, enforce the baseline."
  (let ((total 0)
        (failed nil))
    (dolist (dir '("lisp" "scripts"))
      (dolist (f (directory-files dir t "\\.el\\'"))
        (condition-case err
            (let ((n (length (nl-check-findings-of-kind
                              (nl-check-file f) 'unsafe-call))))
              (when (> n 0)
                (princ (format "%6d  %s\n" n f)))
              (setq total (+ total n)))
          (error
           (princ (format "READ-FAIL %s: %S\n" f err))
           (setq failed t)))))
    (let ((baseline (nl-check-inventory--baseline)))
      (princ (format "unsafe-inventory: total=%d baseline=%s\n"
                     total (or baseline "ABSENT")))
      (cond
       (failed
        (princ "unsafe-inventory: FAIL (unreadable file)\n")
        (kill-emacs 1))
       ((null baseline)
        (princ "unsafe-inventory: FAIL (no baseline file)\n")
        (kill-emacs 1))
       ((> total baseline)
        (princ (format "unsafe-inventory: FAIL (+%d over baseline -- new unsafe-primitive calls outside nl-unsafe; either wrap them or consciously raise the baseline in the same commit)\n"
                       (- total baseline)))
        (kill-emacs 1))
       ((< total baseline)
        (princ (format "unsafe-inventory: PASS (ratchet available: total is %d below baseline; consider lowering %s)\n"
                       (- baseline total)
                       nl-check-inventory--baseline-file)))
       (t (princ "unsafe-inventory: PASS\n"))))))

(nl-check-inventory-run)

;;; nl-check-inventory.el ends here