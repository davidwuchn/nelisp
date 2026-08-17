;;; nelisp-status.el --- generate the repository status snapshot -*- lexical-binding: t; -*-

;;; Commentary:

;; Writes `target/ai/STATUS.json' and `target/ai/STATUS.md': one place an
;; agent can read at the start of a session instead of reconstructing the
;; state of the tree from 168 design documents, a 260 KB findings file and
;; a 76-target Makefile.
;;
;; Two rules keep this file from becoming the thing it replaces.
;;
;; 1. Nothing here is hand-maintained.  A hand-written status section in
;;    a sibling repository claimed "1549 tests, 0 failures" while the
;;    suite actually reported 2859 tests and 127 unexpected results, and
;;    nobody noticed because the number was prose.  Everything below is
;;    derived from git, from the file system, or from gate reports.
;;
;; 2. Nothing here is invented.  Test and gate numbers come only from
;;    reports that exist on this machine; when there are none the output
;;    says "unmeasured" and names the command that would measure it.
;;    "Unmeasured" is a useful answer.  A plausible number is not.
;;
;; The output lands under `target/' — per machine, untracked, and never
;; merged.  A status file in version control drifts from the machine that
;; reads it, which is the failure mode this exists to end.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst nelisp-status-schema "nelisp-status/1")

(defun nelisp-status--git (&rest args)
  "Run git with ARGS, returning trimmed output or nil on failure."
  (condition-case nil
      (with-temp-buffer
        (let ((exit (apply #'call-process "git" nil t nil args)))
          (and (eq exit 0)
               (string-trim (buffer-string)))))
    (error nil)))

(defun nelisp-status--count-lines (string)
  (if (or (null string) (string-empty-p string))
      0
    (length (split-string string "\n" t))))

(defun nelisp-status--files (dir pattern)
  (if (file-directory-p dir)
      (length (directory-files dir nil pattern))
    0))

(defun nelisp-status--make-targets ()
  "Count declared targets in the root Makefile."
  (if (not (file-readable-p "Makefile"))
      0
    (with-temp-buffer
      (insert-file-contents "Makefile")
      (goto-char (point-min))
      (let ((n 0))
        (while (re-search-forward "^[a-zA-Z0-9_.-]+:" nil t)
          (setq n (1+ n)))
        n))))

(defconst nelisp-status--status-buckets
  '(("shipped" "shipped" "implemented" "fixed" "closed" "done" "complete"
     "completed" "merged")
    ("locked" "locked")
    ("draft" "draft" "design" "blueprint" "roadmap" "planned" "proposal" "spec")
    ("blocked" "blocked" "pending" "deferred" "superseded" "stalled"))
  "Leading `#+STATUS:' keywords mapped to a coarse bucket.

The status lines in `docs/design' are free prose — often several
sentences, sometimes Japanese, occasionally a whole changelog — so only
the first word is classified.  Anything unrecognised lands in `other'.
Nothing is rounded up to `shipped': a document whose state cannot be
read mechanically is reported as unread, not as finished.")

(defun nelisp-status--normalize-status (raw)
  "Return the coarse bucket for the raw `#+STATUS:' text RAW."
  (let* ((words (split-string (or raw "") "[ \t—:：,、()（）/]+" t))
         (first (and words (downcase (car words)))))
    (cond ((null first) "unknown")
          ((cl-find-if (lambda (bucket) (member first (cdr bucket)))
                       nelisp-status--status-buckets)
           (car (cl-find-if (lambda (bucket) (member first (cdr bucket)))
                            nelisp-status--status-buckets)))
          (t "other"))))

(defun nelisp-status--design-docs ()
  "Return a plist describing `docs/design/*.org'.

:total      document count
:by-status  hash of coarse bucket -> count
:open       ((FILE . RAW-STATUS) ...) for everything not bucketed as
            shipped, newest file first — the list an agent actually
            needs, since \"what is unfinished\" is the question and
            \"what is done\" is the long tail.

A document with no `#+STATUS:' keyword is counted as `unknown' rather
than guessed at."
  (let ((files (and (file-directory-p "docs/design")
                    (directory-files "docs/design" t "\\.org\\'")))
        (by-status (make-hash-table :test #'equal))
        (open '()))
    (dolist (file files)
      (let ((raw nil))
        (with-temp-buffer
          (insert-file-contents file nil 0 4000)
          (goto-char (point-min))
          (when (re-search-forward "^#\\+STATUS:[ \t]*\\(.+\\)$" nil t)
            (setq raw (string-trim (match-string 1)))))
        (let ((bucket (if raw (nelisp-status--normalize-status raw) "unknown")))
          (puthash bucket (1+ (gethash bucket by-status 0)) by-status)
          (unless (equal bucket "shipped")
            (push (list (file-name-nondirectory file)
                        (truncate-string-to-width (or raw "(no #+STATUS:)") 70 nil nil "…")
                        (float-time (file-attribute-modification-time
                                     (file-attributes file))))
                  open)))))
    (list :total (length files)
          :by-status by-status
          ;; Ordered by mtime, not by name: document 100 is not newer than
          ;; document 99 in any sense a reader cares about, and the point
          ;; of the list is "what has been touched lately".
          :open (mapcar (lambda (entry) (cons (nth 0 entry) (nth 1 entry)))
                        (sort (nreverse open)
                              (lambda (a b) (> (nth 2 a) (nth 2 b))))))))

(defun nelisp-status--gates ()
  "Summarise the gate reports present on this machine."
  (let* ((dir (file-name-as-directory
               (or (getenv "NELISP_GATE_DIR") (expand-file-name "target/gates"))))
         (files (and (file-directory-p dir) (directory-files dir t "\\.json\\'")))
         (counts (list (cons "pass" 0) (cons "fail" 0) (cons "skip" 0)
                       (cons "other" 0)))
         (oldest nil)
         (ran-total 0))
    (dolist (file files)
      (condition-case nil
          (let* ((report (with-temp-buffer
                           (let ((coding-system-for-read 'utf-8))
                             (insert-file-contents file))
                           (goto-char (point-min))
                           (json-parse-buffer :object-type 'alist
                                              :array-type 'list)))
                 (status (or (alist-get 'status report) "other"))
                 (key (if (assoc status counts) status "other"))
                 (finished (alist-get 'finished report))
                 (age (and (stringp finished)
                           (condition-case nil
                               (/ (float-time
                                   (time-subtract (current-time)
                                                  (date-to-time finished)))
                                  3600.0)
                             (error nil)))))
            (setf (alist-get key counts nil nil #'equal)
                  (1+ (alist-get key counts 0 nil #'equal)))
            (setq ran-total (+ ran-total (or (alist-get 'ran report) 0)))
            (when (and age (or (null oldest) (> age oldest)))
              (setq oldest age)))
        (error
         (setf (alist-get "other" counts 0 nil #'equal)
               (1+ (alist-get "other" counts 0 nil #'equal))))))
    (list :reports (length files)
          :pass (alist-get "pass" counts 0 nil #'equal)
          :fail (alist-get "fail" counts 0 nil #'equal)
          :skip (alist-get "skip" counts 0 nil #'equal)
          :other (alist-get "other" counts 0 nil #'equal)
          :cases-executed ran-total
          :oldest-age-hours oldest)))

(defun nelisp-status--json-escape (string)
  (let ((out "\""))
    (dolist (ch (append (or string "") nil))
      (setq out (concat out (cond ((eq ch ?\") "\\\"")
                                  ((eq ch ?\\) "\\\\")
                                  ((eq ch ?\n) "\\n")
                                  ((< ch 32) (format "\\u%04x" ch))
                                  (t (char-to-string ch))))))
    (concat out "\"")))

(defun nelisp-status--json (value)
  (cond ((integerp value) (number-to-string value))
        ((floatp value) (format "%.1f" value))
        ((stringp value) (nelisp-status--json-escape value))
        ((null value) "null")
        (t (nelisp-status--json-escape (format "%s" value)))))

(defun nelisp-status-run ()
  "Write STATUS.json and STATUS.md under `target/ai/'."
  (let* ((out-dir (file-name-as-directory (expand-file-name "target/ai")))
         (branch (or (nelisp-status--git "rev-parse" "--abbrev-ref" "HEAD") "?"))
         (head (or (nelisp-status--git "rev-parse" "--short" "HEAD") "?"))
         (head-subject (or (nelisp-status--git "log" "-1" "--pretty=%s") ""))
         (head-date (or (nelisp-status--git "log" "-1" "--date=short"
                                            "--pretty=%ad")
                        ""))
         (dirty (nelisp-status--count-lines
                 (nelisp-status--git "status" "--porcelain=v1" "--untracked-files=no")))
         (untracked (nelisp-status--count-lines
                     (nelisp-status--git "ls-files" "--others" "--exclude-standard")))
         (worktrees (max 0 (1- (nelisp-status--count-lines
                                (nelisp-status--git "worktree" "list")))))
         (docs (nelisp-status--design-docs))
         (gates (nelisp-status--gates))
         (inventory
          (list (cons "src_el" (nelisp-status--files "src" "\\.el\\'"))
                (cons "lisp_el" (nelisp-status--files "lisp" "\\.el\\'"))
                (cons "test_el" (nelisp-status--files "test" "-test\\.el\\'"))
                (cons "packages" (length (and (file-directory-p "packages")
                                              (directory-files "packages" nil
                                                               "\\`[^.]"))))
                (cons "design_docs" (plist-get docs :total))
                (cons "design_docs_open" (length (plist-get docs :open)))
                (cons "make_targets" (nelisp-status--make-targets))
                (cons "recipes" (nelisp-status--files "recipes" "\\`[^.]"))))
         (measured (> (plist-get gates :reports) 0))
         (generated (format-time-string "%Y-%m-%dT%H:%M:%S%z")))
    (make-directory out-dir t)
    ;; JSON
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name "STATUS.json" out-dir)
        (insert "{\n")
        (insert (format "  \"schema\": %s,\n" (nelisp-status--json nelisp-status-schema)))
        (insert (format "  \"generated\": %s,\n" (nelisp-status--json generated)))
        (insert (format "  \"host\": %s,\n" (nelisp-status--json (system-name))))
        (insert "  \"repo\": {\n")
        (insert (format "    \"branch\": %s,\n" (nelisp-status--json branch)))
        (insert (format "    \"head\": %s,\n" (nelisp-status--json head)))
        (insert (format "    \"head_date\": %s,\n" (nelisp-status--json head-date)))
        (insert (format "    \"head_subject\": %s,\n" (nelisp-status--json head-subject)))
        (insert (format "    \"modified_tracked\": %s,\n" (nelisp-status--json dirty)))
        (insert (format "    \"untracked\": %s,\n" (nelisp-status--json untracked)))
        (insert (format "    \"other_worktrees\": %s\n" (nelisp-status--json worktrees)))
        (insert "  },\n")
        (insert "  \"inventory\": {\n")
        (insert (mapconcat (lambda (pair)
                             (format "    %s: %s"
                                     (nelisp-status--json-escape (car pair))
                                     (nelisp-status--json (cdr pair))))
                           inventory ",\n"))
        (insert "\n  },\n")
        (insert "  \"design_doc_status\": {\n")
        (insert (mapconcat #'identity
                           (let (rows)
                             (maphash (lambda (k v)
                                        (push (format "    %s: %s"
                                                      (nelisp-status--json-escape k)
                                                      (nelisp-status--json v))
                                              rows))
                                      (plist-get docs :by-status))
                             (nreverse rows))
                           ",\n"))
        (insert "\n  },\n")
        (insert "  \"design_docs_open\": [\n")
        (insert (mapconcat (lambda (pair)
                             (format "    { \"file\": %s, \"status\": %s }"
                                     (nelisp-status--json-escape (car pair))
                                     (nelisp-status--json-escape (cdr pair))))
                           (plist-get docs :open) ",\n"))
        (insert "\n  ],\n")
        (insert "  \"gates\": {\n")
        (insert (format "    \"measured\": %s,\n" (if measured "true" "false")))
        (insert (format "    \"reports\": %s,\n" (nelisp-status--json (plist-get gates :reports))))
        (insert (format "    \"pass\": %s,\n" (nelisp-status--json (plist-get gates :pass))))
        (insert (format "    \"fail\": %s,\n" (nelisp-status--json (plist-get gates :fail))))
        (insert (format "    \"skip\": %s,\n" (nelisp-status--json (plist-get gates :skip))))
        (insert (format "    \"other\": %s,\n" (nelisp-status--json (plist-get gates :other))))
        (insert (format "    \"cases_executed\": %s,\n"
                        (nelisp-status--json (plist-get gates :cases-executed))))
        (insert (format "    \"oldest_report_age_hours\": %s\n"
                        (nelisp-status--json (plist-get gates :oldest-age-hours))))
        (insert "  }\n}\n")))
    ;; Markdown
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name "STATUS.md" out-dir)
        (insert "# nelisp — status snapshot\n\n")
        (insert (format "Generated %s on `%s`.  Regenerate with `tools/ai/nelisp-ai.sh status`.\n"
                        generated (system-name)))
        (insert "This file is machine-generated and untracked; do not edit it.\n\n")
        (insert "## Working tree\n\n")
        (insert (format "- branch `%s` at `%s` (%s) — %s\n" branch head head-date head-subject))
        (insert (format "- %d modified tracked file(s), %d untracked\n" dirty untracked))
        (insert (format "- %d other worktree(s) attached to this repository\n" worktrees))
        (when (> worktrees 0)
          (insert "  - another session may hold a branch; check `git worktree list` before switching\n"))
        (insert "\n## Inventory\n\n")
        (insert "| what | count |\n|---|---|\n")
        (dolist (pair inventory)
          (insert (format "| %s | %d |\n" (car pair) (cdr pair))))
        (insert "\n## Design documents\n\n")
        (insert (format "%d document(s) in `docs/design/`, bucketed by the first word of `#+STATUS:`\n\n"
                        (plist-get docs :total)))
        (insert "| status | count |\n|---|---|\n")
        (let (rows)
          (maphash (lambda (k v) (push (cons k v) rows)) (plist-get docs :by-status))
          (dolist (row (sort rows (lambda (a b) (> (cdr a) (cdr b)))))
            (insert (format "| %s | %d |\n" (car row) (cdr row)))))
        (insert "\n`unknown` = no `#+STATUS:` keyword at all; `other` = a status this tool\ncannot classify.  Neither is evidence of progress in either direction.\n")
        (insert (format "\n### Not marked shipped (%d, newest first — full list in STATUS.json)\n\n"
                        (length (plist-get docs :open))))
        (dolist (pair (seq-take (plist-get docs :open) 15))
          (insert (format "- `%s` — %s\n" (car pair) (cdr pair))))
        (insert "\n## Gates\n\n")
        (if (not measured)
            (insert "**Unmeasured on this machine.**  No gate report exists under `target/gates/`.\nRun `tools/ai/nelisp-ai.sh verify` before relying on any claim about what passes.\n")
          (insert (format "%d report(s): %d pass, %d fail, %d skip, %d other; %d case(s) executed.\n"
                          (plist-get gates :reports)
                          (plist-get gates :pass)
                          (plist-get gates :fail)
                          (plist-get gates :skip)
                          (plist-get gates :other)
                          (plist-get gates :cases-executed)))
          (when (plist-get gates :oldest-age-hours)
            (insert (format "Oldest report is %.1f hour(s) old.\n"
                            (plist-get gates :oldest-age-hours))))
          (insert "\nRun `tools/ai/nelisp-ai.sh verify` for the per-gate table and the verdict.\n"))))
    (princ (format "wrote %sSTATUS.json and %sSTATUS.md\n" out-dir out-dir))))

(provide 'nelisp-status)

;;; nelisp-status.el ends here
