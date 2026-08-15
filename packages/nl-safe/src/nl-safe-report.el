;;; nl-safe-report.el --- Persist and summarize nl-safe violation logs -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 168 Phase 6 gate data collection (design input per Doc 170
;; section 3.3): the go/no-go decision for the static checker is
;; "start only if > 50% of dynamically caught violations were
;; statically decidable".  This file is the plumbing that turns the
;; in-process `nl-safe--violation-log' into durable, classifiable
;; data:
;;
;;   `nl-safe-report-dump'           log -> file (printable sexps,
;;                                   one record per line, append)
;;   `nl-safe-report-load'           file -> list of records
;;   `nl-safe-report-summarize'      records -> counts (by kind, by
;;                                   cell, static yes/no/unknown)
;;   `nl-safe-report-summarize-file' load + summarize in one call
;;   `nl-safe-report-clear'          empty the in-process log
;;
;; Each dumped record gains a `:static' field defaulting to the
;; symbol `unknown'.  A human (or a later tool) edits the dump file,
;; flipping `unknown' to `yes' (a static checker could have caught
;; this violation) or `no' (it could not).  The summary only counts
;; the three states; computing the 50% ratio and making the call is
;; deliberately left to the human reading the numbers.
;;
;; Dual-target file I/O: host Emacs uses `write-region' /
;; `insert-file-contents'; the standalone binary has neither in its
;; base image, but provides the `wrf' (write file, truncate) and
;; `rdf' (read file, "" when missing) builtins, plus
;; `nelisp--read-all-from-string-native' for bulk parsing.  Dispatch
;; is by `fboundp' on the standalone-only builtins, called through
;; quoted symbols so host byte-compilation stays warning-free.
;; NOTE: the standalone's `file-exists-p' is unreliable (returns nil
;; for existing files), so this file never calls it on that path;
;; "missing file" is detected as `rdf' returning "".
;;
;; Design constraints (same as nl-safe.el): pure Lisp, no cl-lib, no
;; `documentation' / `display-warning', runs unchanged on host Emacs
;; and on `target/nelisp' standalone.

;;; Code:

(require 'nl-safe)

;;;; Portable file I/O --------------------------------------------------

(defun nl-safe-report--read-file (path)
  "Return the contents of PATH as a string; \"\" when unreadable.
Uses the standalone `rdf' builtin when present, else host Emacs
`insert-file-contents'."
  (if (fboundp 'rdf)
      (funcall 'rdf path)
    (if (file-exists-p path)
        (with-temp-buffer
          (insert-file-contents path)
          (buffer-string))
      "")))

(defun nl-safe-report--write-file (path string)
  "Write STRING to PATH, truncating any existing contents."
  (if (fboundp 'wrf)
      (funcall 'wrf path string)
    (write-region string nil path nil 0))
  nil)

(defun nl-safe-report--append-file (path string)
  "Append STRING to PATH, creating the file when missing.
The standalone `wrf' builtin only truncates, so on that path append
is emulated as read + concat + rewrite."
  (if (fboundp 'wrf)
      (funcall 'wrf path
               (concat (nl-safe-report--read-file path) string))
    (write-region string nil path t 0))
  nil)

(defun nl-safe-report--read-forms (string)
  "Parse every top-level sexp in STRING; return them as a list.
Uses the standalone's native bulk reader when present, else a
`read-from-string' loop on host Emacs."
  (if (fboundp 'nelisp--read-all-from-string-native)
      (funcall 'nelisp--read-all-from-string-native string)
    (let ((pos 0)
          (forms nil)
          (done nil))
      (while (not done)
        (condition-case nil
            (let ((res (read-from-string string pos)))
              (setq forms (cons (car res) forms))
              (setq pos (cdr res)))
          (end-of-file (setq done t))))
      (reverse forms))))

;;;; Records ------------------------------------------------------------

(defun nl-safe-report--ensure-static (record)
  "Return RECORD with a `:static' classification field present.
When missing it is appended with the value `unknown' (the human
classifier flips it to `yes' or `no' in the dump file later)."
  (if (plist-get record :static)
      record
    (append record (list :static 'unknown))))

;;;; Dump / load / clear -------------------------------------------------

(defun nl-safe-report-dump (path &optional clear)
  "Append `nl-safe--violation-log' to the file PATH; return the count.
Records are written oldest first (the file stays chronological), one
printable sexp per line, each with a `:static' field defaulting to
`unknown' (see `nl-safe-report--ensure-static').  The in-process log
is left untouched unless CLEAR is non-nil, in which case it is
emptied after a successful write.  With an empty log nothing is
written and 0 is returned."
  (let ((records (reverse nl-safe--violation-log))
        (lines "")
        (count 0))
    (let ((rest records))
      (while rest
        (setq lines
              (concat lines
                      (prin1-to-string
                       (nl-safe-report--ensure-static (car rest)))
                      "\n"))
        (setq count (1+ count))
        (setq rest (cdr rest))))
    (when (> count 0)
      (nl-safe-report--append-file path lines)
      (when clear
        (setq nl-safe--violation-log nil)))
    count))

(defun nl-safe-report-load (path)
  "Read the violation records dumped to PATH; nil when none.
Records come back in file order (chronological for files written by
`nl-safe-report-dump')."
  (nl-safe-report--read-forms (nl-safe-report--read-file path)))

(defun nl-safe-report-clear ()
  "Empty the in-process `nl-safe--violation-log'.
Return the number of records dropped."
  (let ((n (length nl-safe--violation-log)))
    (setq nl-safe--violation-log nil)
    n))

;;;; Summary -------------------------------------------------------------

(defun nl-safe-report--tally (key alist)
  "Add one occurrence of KEY to the count ALIST; return the alist.
ALIST maps keys to integer counts (`assq' keying); a fresh entry is
consed on first sight, so callers must use the return value."
  (let ((entry (assq key alist)))
    (if entry
        (progn (setcdr entry (1+ (cdr entry))) alist)
      (cons (cons key 1) alist))))

(defun nl-safe-report-summarize (records)
  "Summarize the violation RECORDS list for the Phase 6 gate.
Return a plist:

  :total    total record count
  :by-kind  alist (KIND . COUNT), first-seen order
  :by-cell  alist (CELL . COUNT) over records carrying a `:cell'
  :static   plist (:yes N :no N :unknown N) from each record's
            `:static' field; anything other than `yes' / `no'
            (including a missing field) counts as unknown

The summary only counts; deciding whether the statically-decidable
share exceeds the 50% gate is the reader's call."
  (let ((total 0)
        (by-kind nil)
        (by-cell nil)
        (yes 0)
        (no 0)
        (unknown 0)
        (rest records))
    (while rest
      (let* ((rec (car rest))
             (cell (plist-get rec :cell))
             (static (plist-get rec :static)))
        (setq total (1+ total))
        (setq by-kind (nl-safe-report--tally (plist-get rec :kind) by-kind))
        (when cell
          (setq by-cell (nl-safe-report--tally cell by-cell)))
        (cond ((eq static 'yes) (setq yes (1+ yes)))
              ((eq static 'no) (setq no (1+ no)))
              (t (setq unknown (1+ unknown)))))
      (setq rest (cdr rest)))
    (list :total total
          :by-kind (reverse by-kind)
          :by-cell (reverse by-cell)
          :static (list :yes yes :no no :unknown unknown))))

(defun nl-safe-report-summarize-file (path)
  "Load the dump file PATH and return its `nl-safe-report-summarize'."
  (nl-safe-report-summarize (nl-safe-report-load path)))

(provide 'nl-safe-report)

;;; nl-safe-report.el ends here
