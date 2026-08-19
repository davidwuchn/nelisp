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
  "Read the integer baseline, or nil when there is no `unsafe-call\=' line.
A named line rather than the whole buffer, so the file can carry the
reason for its number the way tools/ns-inventory-baseline.txt and
tools/fallback-inventory-baseline.txt carry theirs -- `string-to-number\='
on the buffer would read 0 from any file that led with a comment, and
a baseline of 0 is a different claim from an unreadable one."
  (when (file-exists-p nl-check-inventory--baseline-file)
    (with-temp-buffer
      (insert-file-contents nl-check-inventory--baseline-file)
      (goto-char (point-min))
      (when (re-search-forward "^unsafe-call +\\([0-9]+\\)" nil t)
        (string-to-number (match-string 1))))))

(defconst nl-check-inventory--quoted-top 6
  "How many files to name in the quoted-form report.")

(defun nl-check-inventory--report-quoted (rows total)
  "Print the quoted-form tally: ROWS is (FILE . COUNT), TOTAL their sum.
Reported, never gated.  A gate that says 531 without saying what it
excludes gets read as \"531 is the unsafe surface\", and here that is
wrong by an order of magnitude: this tree writes its runtime as quoted
generator bodies, so most of the unsafe kernel is inside a quote and
the scan steps over all of it by design (the same rule correctly
excludes opcode tables like (ptr-read-u16 . 39), which are data).
Printing the excluded count turns a silent exclusion into a stated
one, and leaves the question of whether to gate it to whoever reads
the number."
  (princ (format "\n  not counted, inside quoted forms (reported, not gated): %d\n"
                 total))
  (let ((shown 0))
    (dolist (row rows)
      (when (< shown nl-check-inventory--quoted-top)
        (princ (format "%6d  %s\n" (cdr row) (car row)))
        (setq shown (+ shown 1)))))
  (when (> (length rows) nl-check-inventory--quoted-top)
    (princ (format "         ... and %d more file(s)\n"
                   (- (length rows) nl-check-inventory--quoted-top)))))

(defun nl-check-inventory-run ()
  "Scan lisp/ and scripts/, print the inventory, enforce the baseline."
  (let ((total 0)
        (scanned 0)
        (failed nil)
        (quoted-total 0)
        (quoted-rows nil))
    (dolist (dir '("lisp" "scripts"))
      (dolist (f (directory-files dir t "\\.el\\'"))
        (setq scanned (+ scanned 1))
        (condition-case err
            (let ((n (length (nl-check-findings-of-kind
                              (nl-check-file f) 'unsafe-call)))
                  (q (length (nl-check-file-quoted-unsafe f))))
              (when (> n 0)
                (princ (format "%6d  %s\n" n f)))
              (setq total (+ total n))
              (setq quoted-total (+ quoted-total q))
              (when (> q 0)
                (setq quoted-rows (cons (cons f q) quoted-rows))))
          (error
           (princ (format "READ-FAIL %s: %S\n" f err))
           (setq failed t)))))
    (nl-check-inventory--report-quoted
     (sort quoted-rows (lambda (a b) (> (cdr a) (cdr b))))
     quoted-total)
    (let ((baseline (nl-check-inventory--baseline)))
      (princ (format "unsafe-inventory: total=%d baseline=%s\n"
                     total (or baseline "ABSENT")))
      ;; Machine-readable tail, before the verdict so it survives every
      ;; exit path.  `total' counts findings; `checked' counts files,
      ;; and only the second one can show that the scan happened at all
      ;; (contract: tools/ai/README.md).
      (princ (format "GATE-COUNT checked=%d findings=%d\n" scanned total))
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