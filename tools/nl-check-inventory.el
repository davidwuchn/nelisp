;;; nl-check-inventory.el --- CI unsafe-surface inventory via nl-check -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 170 section 4.3: "have nl-check report the unsafe surface and
;; track its growth in CI", and the safe-core/unsafe-kernel structure the
;; same section cites from Rust.
;;
;; Two questions, and only one of them is a number.
;;
;; ESCAPE (gated, no baseline).  Every file under lisp/ and scripts/ that
;; tools/unsafe-kernel.txt does not name must contain no unsafe-primitive
;; call at all, quoted or not.  Raw memory leaving the kernel is the event
;; worth stopping, it is yes/no, and it dissolves the quoted-form problem:
;; a generator body and a plain call are the same question once the
;; question is "does this file belong to the kernel".
;;
;; GROWTH (reported).  Inside the kernel the counts are printed, with the
;; number of kernel files ratcheted against that file.  The call count is
;; not gated: these files are made of raw memory operations and the count
;; moves whenever the runtime does, so ratcheting it would mean a baseline
;; bump in most runtime commits -- friction that teaches people to bump
;; without reading, which is how a gate stops being read at all.  Batch driver: scan every .el under lisp/
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

(defconst nl-check-inventory--kernel-file
  "tools/unsafe-kernel.txt")

(defun nl-check-inventory--kernel ()
  "Return (PATTERNS . COUNT) from the kernel file, or nil when unreadable.
PATTERNS are anchored regexps; COUNT is the ratcheted number of kernel
files that hold an unsafe call, or nil when the file names no count."
  (when (file-exists-p nl-check-inventory--kernel-file)
    (with-temp-buffer
      (insert-file-contents nl-check-inventory--kernel-file)
      (goto-char (point-min))
      (let ((patterns nil) (count nil))
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring (line-beginning-position)
                                                     (line-end-position)))))
            (cond
             ((or (string-empty-p line) (string-prefix-p "#" line)) nil)
             ((string-match "\\`kernel-files +\\([0-9]+\\)\\'" line)
              (setq count (string-to-number (match-string 1 line))))
             (t (setq patterns
                      (cons (concat "\\`" (wildcard-to-regexp line))
                            patterns)))))
          (forward-line 1))
        (cons (nreverse patterns) count)))))

(defun nl-check-inventory--kernel-p (path patterns)
  "Return non-nil when PATH is inside the kernel described by PATTERNS."
  (let ((rel (file-relative-name path))
        (hit nil))
    (dolist (rx patterns)
      (when (string-match-p rx rel) (setq hit t)))
    hit))

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
  (let* ((kernel (nl-check-inventory--kernel))
         (kernel-patterns (car kernel))
         (kernel-baseline (cdr kernel))
         (kernel-count 0)
         (escapes nil)
         (total 0)
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
                (setq quoted-rows (cons (cons f q) quoted-rows)))
              (when (> (+ n q) 0)
                (if (nl-check-inventory--kernel-p f kernel-patterns)
                    (setq kernel-count (+ kernel-count 1))
                  (setq escapes (cons (list (file-relative-name f) n q)
                                      escapes)))))
          (error
           (princ (format "READ-FAIL %s: %S\n" f err))
           (setq failed t)))))
    (nl-check-inventory--report-quoted
     (sort quoted-rows (lambda (a b) (> (cdr a) (cdr b))))
     quoted-total)
    (princ (format "\n  unsafe kernel: %d file(s) hold a call, baseline %s\n"
                   kernel-count (or kernel-baseline "ABSENT")))
    (when escapes
      (princ (format "  OUTSIDE the kernel: %d file(s)\n" (length escapes)))
      (dolist (e (sort escapes (lambda (a b) (string< (car a) (car b)))))
        (princ (format "      %-46s call=%-4d quoted=%d\n"
                       (nth 0 e) (nth 1 e) (nth 2 e)))))
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
       ((null kernel-patterns)
        (princ (format "unsafe-inventory: FAIL (no kernel patterns in %s)\n"
                       nl-check-inventory--kernel-file))
        (kill-emacs 1))
       (escapes
        (princ (format "unsafe-inventory: FAIL (%d file(s) outside the kernel call an unsafe primitive -- move the code into a kernel file, or add the file to %s and say there what it does with raw memory)\n"
                       (length escapes) nl-check-inventory--kernel-file))
        (kill-emacs 1))
       ((null kernel-baseline)
        (princ (format "unsafe-inventory: FAIL (no kernel-files line in %s)\n"
                       nl-check-inventory--kernel-file))
        (kill-emacs 1))
       ((> kernel-count kernel-baseline)
        (princ (format "unsafe-inventory: FAIL (%d kernel file(s) hold an unsafe call, baseline %d -- a file the patterns already covered has started touching raw memory; raise the baseline and say there what it does)\n"
                       kernel-count kernel-baseline))
        (kill-emacs 1))
       ((null baseline)
        (princ "unsafe-inventory: FAIL (no baseline file)\n")
        (kill-emacs 1))
       ((> total baseline)
        (princ (format "unsafe-inventory: FAIL (+%d over baseline -- new unsafe-primitive calls outside nl-unsafe; either wrap them or consciously raise the baseline in the same commit)\n"
                       (- total baseline)))
        (kill-emacs 1))
       (t
        (when (< kernel-count kernel-baseline)
          (princ (format "    ratchet available: %d kernel file(s), %d below baseline\n"
                         kernel-count (- kernel-baseline kernel-count))))
        (when (< total baseline)
          (princ (format "    ratchet available: unsafe-call is %d below baseline\n"
                         (- baseline total))))
        (princ "unsafe-inventory: PASS\n"))))))

(nl-check-inventory-run)

;;; nl-check-inventory.el ends here