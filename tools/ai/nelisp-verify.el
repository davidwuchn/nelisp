;;; nelisp-verify.el --- aggregate gate reports into one verdict -*- lexical-binding: t; -*-

;;; Commentary:

;; Reads every report in the gate directory, checks them against the
;; expected-gate manifest (`tools/ai/gates.expected'), and prints one
;; table plus one verdict line.
;;
;; The manifest is the half that catches the failure an exit code cannot:
;; a gate that never ran leaves no report behind, so only a list of gates
;; that *should* exist can tell the difference between "green" and "never
;; reached".  In this repository a CI gate once sat behind an already-red
;; target for its entire life and was reported as passing throughout.
;;
;; Reports also carry their own age.  A fresh-looking green table built
;; from last week's runs is its own kind of lie, so the age is always
;; printed, and `NELISP_VERIFY_MAX_AGE_HOURS' turns staleness into a
;; failure when a caller wants that (CI should set it).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defun nelisp-verify--gate-directory ()
  (file-name-as-directory
   (or (getenv "NELISP_GATE_DIR") (expand-file-name "target/gates"))))

(defun nelisp-verify--manifest-file ()
  (or (getenv "NELISP_GATE_MANIFEST")
      (expand-file-name "tools/ai/gates.expected")))

(defun nelisp-verify--expected ()
  "Return the expected gate names from the manifest, in file order.
Blank lines and `#' comments are ignored.  A trailing `?' on a name
marks the gate optional: it is reported when present but its absence is
not a failure."
  (let ((file (nelisp-verify--manifest-file))
        (out '()))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (string-trim (buffer-substring-no-properties
                                    (line-beginning-position)
                                    (line-end-position)))))
            (unless (or (string-empty-p line) (string-prefix-p "#" line))
              (if (string-suffix-p "?" line)
                  (push (cons (substring line 0 -1) 'optional) out)
                (push (cons line 'required) out))))
          (forward-line 1))))
    (nreverse out)))

(defun nelisp-verify--read-report (file)
  "Parse FILE, returning an alist, or a synthetic unreadable report."
  (condition-case err
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (goto-char (point-min))
        (json-parse-buffer :object-type 'alist :array-type 'list))
    (error
     (list (cons 'name (file-name-base file))
           (cons 'status "unreadable")
           (cons 'ran 0)
           (cons 'failed 0)
           (cons 'skipped 0)
           (cons 'reason (format "cannot parse report: %s"
                                 (error-message-string err)))))))

(defun nelisp-verify--reports ()
  "Return (NAME . ALIST) for every report in the gate directory."
  (let ((dir (nelisp-verify--gate-directory)))
    (when (file-directory-p dir)
      (mapcar (lambda (file)
                (let ((report (nelisp-verify--read-report file)))
                  (cons (or (alist-get 'name report) (file-name-base file))
                        report)))
              (sort (directory-files dir t "\\.json\\'") #'string<)))))

(defun nelisp-verify--age-hours (report)
  "Return REPORT's age in hours, or nil when its timestamp is unusable."
  (let ((finished (alist-get 'finished report)))
    (when (and (stringp finished) (> (length finished) 0))
      (condition-case nil
          (/ (float-time (time-subtract (current-time)
                                        (date-to-time finished)))
             3600.0)
        (error nil)))))

(defun nelisp-verify-run ()
  "Print the gate table and exit 0 only when every required gate is green."
  (let* ((reports (nelisp-verify--reports))
         (expected (nelisp-verify--expected))
         (max-age (let ((raw (getenv "NELISP_VERIFY_MAX_AGE_HOURS")))
                    (and raw (> (length (string-trim raw)) 0)
                         (string-to-number raw))))
         (problems '())
         (rows '()))
    ;; Every expected gate, present or not.
    (dolist (entry expected)
      (let* ((name (car entry))
             (requirement (cdr entry))
             (report (alist-get name reports nil nil #'equal)))
        (cond
         ((null report)
          (push (list name (if (eq requirement 'optional) "absent" "MISSING")
                      0 0 0 nil
                      (if (eq requirement 'optional)
                          "optional gate, no report"
                        ;; ASCII only: this line is printed to a console
                        ;; whose encoding is not guaranteed, and a reason
                        ;; that arrives mangled is a reason nobody reads.
                        "gate produced no report -- it did not run"))
                rows)
          (when (eq requirement 'required)
            (push (format "%s: no report (the gate never ran)" name) problems)))
         (t
          (let* ((status (alist-get 'status report))
                 (age (nelisp-verify--age-hours report))
                 (stale (and max-age age (> age max-age))))
            (push (list name status
                        (or (alist-get 'ran report) 0)
                        (or (alist-get 'failed report) 0)
                        (or (alist-get 'skipped report) 0)
                        age
                        (or (alist-get 'reason report) ""))
                  rows)
            (unless (member status '("pass" "skip"))
              (push (format "%s: %s (%s)" name status
                            (or (alist-get 'reason report) "no reason given"))
                    problems))
            (when stale
              (push (format "%s: report is %.1fh old (limit %.1fh)"
                            name age max-age)
                    problems)))))))
    ;; Reports with no manifest entry: shown, never silently trusted.
    (dolist (pair reports)
      (unless (assoc (car pair) expected)
        (let ((report (cdr pair)))
          (push (list (car pair)
                      (format "%s*" (alist-get 'status report))
                      (or (alist-get 'ran report) 0)
                      (or (alist-get 'failed report) 0)
                      (or (alist-get 'skipped report) 0)
                      (nelisp-verify--age-hours report)
                      "not in gates.expected")
                rows))))
    (setq rows (nreverse rows))
    (princ (format "%-38s %-9s %7s %7s %8s %7s\n"
                   "GATE" "STATUS" "RAN" "FAILED" "SKIPPED" "AGE(h)"))
    (princ (make-string 82 ?-))
    (princ "\n")
    (dolist (row rows)
      (cl-destructuring-bind (name status ran failed skipped age reason) row
        (princ (format "%-38s %-9s %7s %7s %8s %7s\n"
                       name status ran failed skipped
                       (if age (format "%.1f" age) "-")))
        (unless (string-empty-p (or reason ""))
          (princ (format "%42s%s\n" "" reason)))))
    (princ "\n")
    (if problems
        (progn
          (princ (format "VERDICT: FAIL (%d problem(s))\n" (length problems)))
          (dolist (p (nreverse problems))
            (princ (format "  - %s\n" p)))
          (kill-emacs 1))
      (princ (format "VERDICT: PASS (%d gate(s))\n" (length expected)))
      (kill-emacs 0))))

(provide 'nelisp-verify)

;;; nelisp-verify.el ends here
