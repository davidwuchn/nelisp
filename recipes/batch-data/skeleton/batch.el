;;; batch.el --- read a delimited file, aggregate it, write a report -*- lexical-binding: t; -*-

;;; Commentary:

;; The shape most likely to be useful on day one: a short-lived process
;; that reads a file, computes something, writes a file, and exits.  It
;; is also the shape the runtime is currently best at — nothing here is
;; long-lived, so the arena's lack of reclamation never comes up.
;;
;; Paths arrive through variables set before this file is loaded:
;;
;;     (setq batch-input "C:/data/in.csv")
;;     (setq batch-output "C:/data/out.txt")
;;     (load "batch.el" nil t)
;;
;; and fall back to the environment when those are unset.  The
;; environment alone is not enough: `getenv' answers nil for everything
;; on the Linux build -- even HOME -- while it works on Windows
;; (measured 2026-08-18).  Setting a variable before loading works on
;; both, and matches how this runtime loads anything else: by path.
;;
;; Text processing here is string-based on purpose.  `with-temp-buffer',
;; `insert-file-contents' and `buffer-string' all work, but `goto-char'
;; and `re-search-forward' do not exist, so buffer *navigation* is not
;; available.  Read the file in, then work on strings with
;; `split-string' / `string-match' / `substring'.

;;; Code:

(defvar batch-input nil
  "Input path.  Falls back to the BATCH_INPUT environment variable.")

(defvar batch-output nil
  "Output path.  Falls back to the BATCH_OUTPUT environment variable.")

(defvar batch-column nil
  "Zero-based field to group by.  Falls back to BATCH_COLUMN, then 2.")

(defun batch-read-file (path)
  "Return the contents of PATH as a string."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

(defun batch-write-file (path text)
  "Write TEXT to PATH and confirm that it landed.

`write-region' in the standalone runtime checks its own work by
comparing a character count against the byte count the write returned.
For anything multibyte those differ, so a correct write of Japanese text
raises

    write-region stub: wrf returned 28 (expected 20)

*after* the file has been written correctly.  Neither the error nor its
absence is evidence here, so the write is verified by reading the file
back -- which is what you wanted to know anyway.

The read-back deliberately does not consult `file-exists-p': in this
build that predicate answers nil for files that demonstrably exist, so
guarding on it would reject every successful write."
  (ignore-errors (write-region text nil path))
  (let ((written (ignore-errors (batch-read-file path))))
    (unless (equal written text)
      (error "batch: %s does not contain what was written" path))
    written))

(defun batch-rows (text)
  "Split TEXT into a list of comma-separated field lists.
The first line is treated as a header and dropped."
  (let ((lines (split-string text "\n" t))
        (rows '()))
    (dolist (line (cdr lines))
      (let ((trimmed (string-trim line)))
        (when (> (length trimmed) 0)
          (setq rows (cons (split-string trimmed "," nil) rows)))))
    (nreverse rows)))

(defun batch-count-by (rows index)
  "Count ROWS by the field at INDEX, returning an alist."
  (let ((counts '()))
    (dolist (row rows)
      (let* ((key (or (nth index row) ""))
             (hit (assoc key counts)))
        (if hit
            (setcdr hit (1+ (cdr hit)))
          (setq counts (cons (cons key 1) counts)))))
    (nreverse counts)))

(defun batch-render (rows counts)
  "Render the report body for ROWS and COUNTS."
  (concat
   (format "rows: %d\n" (length rows))
   (mapconcat (lambda (pair) (format "%s: %d" (car pair) (cdr pair)))
              counts
              "\n")
   "\n"))

(defun batch-main ()
  "Read `BATCH_INPUT', aggregate it, write `BATCH_OUTPUT'."
  (let* ((input (or batch-input (getenv "BATCH_INPUT")))
         (output (or batch-output (getenv "BATCH_OUTPUT")))
         (column (or batch-column
                     (string-to-number (or (getenv "BATCH_COLUMN") "2")))))
    (if (not (and input output))
        (progn
          (princ "batch.el: set batch-input and batch-output before loading")
          (terpri))
      (let* ((text (batch-read-file input))
             (rows (batch-rows text))
             (counts (batch-count-by rows column)))
        (batch-write-file output (batch-render rows counts))
        (princ (format "wrote %s (%d rows)" output (length rows)))
        (terpri))))
  'batch-done)

(batch-main)

;;; batch.el ends here
