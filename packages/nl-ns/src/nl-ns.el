;;; nl-ns.el --- Namespace boundaries as a checkable declaration -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 169 language defect #6 (no namespaces), addressed as an opt-in
;; development-time library rather than as a reader extension.
;;
;; Elisp has one obarray, so `defun' is assignment to a global name and
;; a second definition silently wins.  The usual response is to invent
;; a namespace by rewriting code -- a macro that turns `foo' into
;; `mypkg-foo' inside a block.  This package deliberately does NOT do
;; that.  Rewriting buys shorter names and pays for them in the
;; debugger, the backtrace, `describe-function', and `M-.', all of
;; which start showing a name the author never wrote.
;;
;; What actually hurts is not that names are long.  It is that
;; collisions are silent, that "this file depends on that file" is
;; nowhere stated, and that the `--' private convention is a comment
;; rather than a rule.  Those three are checkable without touching a
;; single source file, which is what this package does.
;;
;; Public API:
;;
;;   Analysis:  `nl-ns-analyse' `nl-ns-analyse-files'
;;   Checking:  `nl-ns-check' `nl-ns-check-files'
;;   Reporting: `nl-ns-report' `nl-ns-summary'
;;              `nl-ns-findings-of-kind'
;;   Overrides: `nl-ns-declare' `nl-ns-clear-declarations'
;;   Internals worth calling: `nl-ns-file-namespace' `nl-ns-read-file'
;;
;; Findings (same plist shape as nl-check):
;;
;;   ns-collision              symbol defined in more than one file
;;   ns-prefix-violation       definition outside its file's namespace
;;   ns-private-escape         another file's `--' name is referenced
;;   ns-undeclared-dependency  cross-file reference with no `require'
;;   ns-unreadable             the file could not be read
;;
;; Zero configuration by design.  A file's namespace is inferred as the
;; longest hyphen-boundary prefix shared by a majority of the names it
;; defines, so a file that is deliberately global (a stdlib prelude
;; defining `car', `princ', ...) has no dominant prefix and opts itself
;; out of the prefix check.  `nl-ns-declare' overrides the inference
;; where it guesses wrong.
;;
;; Nothing here runs at load time and nothing depends on this package,
;; the same one-way rule `nl-check' follows (Doc 168 section 4.1).
;; Analysis functions take already-read forms so they work on the
;; standalone; only the `*-files' wrappers touch the filesystem.

;;; Code:

(require 'nl-prelude)

;;;; Declarations -----------------------------------------------------

(defvar nl-ns--declared (make-hash-table :test 'equal)
  "Map of FILE (string) -> namespace prefix string, overriding inference.")

(defun nl-ns-declare (file prefix)
  "Declare that definitions in FILE belong to namespace PREFIX.
PREFIX is the literal string every name in FILE should start with,
for example \"nl-safe-\".  Overrides `nl-ns-file-namespace' inference."
  (unless (stringp file)
    (error "nl-ns-declare: FILE must be a string, got %S" file))
  (unless (stringp prefix)
    (error "nl-ns-declare: PREFIX must be a string, got %S" prefix))
  (puthash file prefix nl-ns--declared)
  prefix)

(defun nl-ns-clear-declarations ()
  "Forget every `nl-ns-declare' override."
  (clrhash nl-ns--declared)
  nil)

;;;; Reading -----------------------------------------------------------

(defconst nl-ns-definition-heads
  '(defun defmacro defsubst defalias defvar defconst defcustom
     define-error define-minor-mode define-derived-mode cl-defun
     cl-defmacro cl-defstruct cl-defgeneric cl-defmethod)
  "Heads whose second element names something this pass tracks.")

(defun nl-ns--defined-symbol (form)
  "Return the symbol FORM defines, or nil when FORM defines nothing."
  (and (consp form)
       (memq (car form) nl-ns-definition-heads)
       (let ((name (car (cdr form))))
         (cond
          ((symbolp name) name)
          ;; (defalias 'foo ...) / (define-error 'foo ...)
          ((and (consp name) (eq (car name) 'quote)
                (symbolp (car (cdr name))))
           (car (cdr name)))
          (t nil)))))

(defun nl-ns--quoted-feature (form)
  "Return the feature symbol in FORM's second position, or nil."
  (let ((arg (car (cdr form))))
    (cond
     ((and (consp arg) (eq (car arg) 'quote) (symbolp (car (cdr arg))))
      (car (cdr arg)))
     ((symbolp arg) arg)
     (t nil))))

(defun nl-ns--collect-symbols (form table)
  "Add every symbol occurring in FORM to hash TABLE.
The list spine is walked iteratively: files in this tree hold quoted
forms thousands of elements long, and a recursive cdr walk overflows
on them."
  (let ((tail form))
    (while (consp tail)
      (nl-ns--collect-symbols (car tail) table)
      (setq tail (cdr tail)))
    (cond
     ((symbolp tail) (when tail (puthash tail t table)))
     ((vectorp tail)
      (let ((i 0) (n (length tail)))
        (while (< i n)
          (nl-ns--collect-symbols (aref tail i) table)
          (setq i (1+ i)))))))
  table)

(defun nl-ns-scan-forms (forms)
  "Return a plist describing FORMS, the top-level forms of one file.
Keys: `:defines' (list of symbols, in order), `:requires' and
`:provides' (lists of feature symbols), `:symbols' (hash set of every
symbol mentioned)."
  (let ((defines nil) (requires nil) (provides nil)
        (symbols (make-hash-table :test 'eq)))
    (dolist (form forms)
      (let ((defined (nl-ns--defined-symbol form)))
        (when defined (setq defines (cons defined defines))))
      (when (and (consp form) (eq (car form) 'require))
        (let ((feature (nl-ns--quoted-feature form)))
          (when feature (setq requires (cons feature requires)))))
      (when (and (consp form) (eq (car form) 'provide))
        (let ((feature (nl-ns--quoted-feature form)))
          (when feature (setq provides (cons feature provides)))))
      (nl-ns--collect-symbols form symbols))
    (list :defines (nreverse defines)
          :requires (nreverse requires)
          :provides (nreverse provides)
          :symbols symbols)))

(defun nl-ns-read-file (path)
  "Return the top-level forms of PATH, or the symbol `nl-ns--unreadable'.
Reading only; nothing from PATH is evaluated."
  (condition-case nil
      (let ((forms nil))
        (with-temp-buffer
          (insert-file-contents path)
          (goto-char (point-min))
          (let ((done nil))
            (while (not done)
              (let ((form (condition-case nil
                              (read (current-buffer))
                            (end-of-file 'nl-ns--eof))))
                (if (eq form 'nl-ns--eof)
                    (setq done t)
                  (setq forms (cons form forms)))))))
        (nreverse forms))
    (error 'nl-ns--unreadable)))

;;;; Namespace inference ------------------------------------------------

(defun nl-ns--prefixes (name)
  "Return NAME's hyphen-boundary prefixes, longest first.
\"nl-safe-foo\" yields (\"nl-safe-\" \"nl-\")."
  (let ((out nil) (i 0) (n (length name)))
    (while (< i n)
      (when (eq (aref name i) ?-)
        (setq out (cons (substring name 0 (1+ i)) out)))
      (setq i (1+ i)))
    ;; The scan runs left to right and conses, so `out' already holds
    ;; the longest prefix first.
    out))

(defun nl-ns-file-namespace (file defines)
  "Return the namespace prefix string for FILE given its DEFINES.
An explicit `nl-ns-declare' wins.  Otherwise the answer is the longest
hyphen-boundary prefix shared by more than half of DEFINES, or nil when
no prefix reaches that share -- a file with no dominant prefix is
treated as deliberately global and skips the prefix check."
  (let ((declared (gethash file nl-ns--declared)))
    (if declared
        declared
      (let ((counts (make-hash-table :test 'equal))
            (total (length defines))
            (best nil)
            (best-len 0))
        (dolist (sym defines)
          (dolist (prefix (nl-ns--prefixes (symbol-name sym)))
            (puthash prefix (1+ (or (gethash prefix counts) 0)) counts)))
        (when (> total 0)
          (maphash
           (lambda (prefix count)
             (when (and (> (* 2 count) total)
                        (> (length prefix) best-len))
               (setq best prefix)
               (setq best-len (length prefix))))
           counts))
        best))))

;;;; Analysis -----------------------------------------------------------

(defun nl-ns-analyse (entries)
  "Analyse ENTRIES, a list of (FILE . FORMS), and return an analysis plist.
FORMS may be the symbol `nl-ns--unreadable' for a file that could not
be read.  Keys of the result: `:files' (list of per-file plists),
`:owner' (hash symbol -> list of defining files, newest first),
`:feature-owner' (hash feature symbol -> file that provides it)."
  (let ((files nil)
        (owner (make-hash-table :test 'eq))
        (feature-owner (make-hash-table :test 'eq)))
    (dolist (entry entries)
      (let ((file (car entry))
            (forms (cdr entry)))
        (if (eq forms 'nl-ns--unreadable)
            (setq files (cons (list :file file :unreadable t) files))
          (let* ((scan (nl-ns-scan-forms forms))
                 (defines (plist-get scan :defines))
                 (namespace (nl-ns-file-namespace file defines)))
            (dolist (sym defines)
              ;; Record each file at most once per symbol: defining a
              ;; name twice inside one file is a different problem, and
              ;; this pass is about cross-file ownership.
              (let ((seen (gethash sym owner)))
                (unless (member file seen)
                  (puthash sym (cons file seen) owner))))
            (dolist (feature (plist-get scan :provides))
              (puthash feature file feature-owner))
            (setq files
                  (cons (list :file file
                              :namespace namespace
                              :defines defines
                              :requires (plist-get scan :requires)
                              :provides (plist-get scan :provides)
                              :symbols (plist-get scan :symbols))
                        files))))))
    (list :files (nreverse files)
          :owner owner
          :feature-owner feature-owner)))

(defun nl-ns-analyse-files (paths)
  "Read each of PATHS and return the analysis, as `nl-ns-analyse' does."
  (let ((entries nil))
    (dolist (path paths)
      (setq entries (cons (cons path (nl-ns-read-file path)) entries)))
    (nl-ns-analyse (nreverse entries))))

;;;; Checking ------------------------------------------------------------

(defun nl-ns--private-name-p (name)
  "Return non-nil when NAME follows the `--' private convention."
  (let ((i 0) (n (length name)) (found nil))
    (while (and (< (1+ i) n) (not found))
      (when (and (eq (aref name i) ?-) (eq (aref name (1+ i)) ?-))
        (setq found t))
      (setq i (1+ i)))
    found))

(defun nl-ns--string-prefix-p (prefix string)
  "Return non-nil when STRING starts with PREFIX."
  (and (<= (length prefix) (length string))
       (string= prefix (substring string 0 (length prefix)))))

(defun nl-ns--requires-file-p (entry file analysis)
  "Return non-nil when ENTRY's file requires a feature provided by FILE."
  (let ((feature-owner (plist-get analysis :feature-owner))
        (found nil))
    (dolist (feature (plist-get entry :requires))
      (when (equal (gethash feature feature-owner) file)
        (setq found t)))
    found))

(defun nl-ns--check-collisions (analysis findings)
  "Add one `ns-collision' finding per multiply-defined symbol."
  (let ((owner (plist-get analysis :owner))
        (collisions nil))
    (maphash
     (lambda (sym files)
       (when (cdr files)
         (setq collisions (cons (cons sym (reverse files)) collisions))))
     owner)
    ;; Stable output: sort by symbol name.
    (setq collisions
          (sort collisions
                (lambda (a b) (string< (symbol-name (car a))
                                       (symbol-name (car b))))))
    (dolist (collision collisions)
      (setq findings
            (cons (list :kind 'ns-collision
                        :subject (car collision)
                        :files (cdr collision)
                        :count (length (cdr collision)))
                  findings)))
    findings))

(defun nl-ns--check-prefixes (entry findings)
  "Add `ns-prefix-violation' findings for ENTRY's stray definitions."
  (let ((namespace (plist-get entry :namespace))
        (file (plist-get entry :file)))
    (when namespace
      (dolist (sym (plist-get entry :defines))
        (unless (nl-ns--string-prefix-p namespace (symbol-name sym))
          (setq findings
                (cons (list :kind 'ns-prefix-violation
                            :subject sym :file file :expected namespace)
                      findings)))))
    findings))

(defun nl-ns--check-references (entry analysis check-deps findings)
  "Add cross-file reference findings for ENTRY.
Reports `ns-private-escape' always, and `ns-undeclared-dependency'
only when CHECK-DEPS is non-nil."
  (let* ((file (plist-get entry :file))
         (owner (plist-get analysis :owner))
         (symbols (plist-get entry :symbols))
         (escapes nil)
         (deps (make-hash-table :test 'equal)))
    (when symbols
      (maphash
       (lambda (sym _v)
         (let ((definers (gethash sym owner)))
           ;; Only symbols defined exactly once elsewhere are attributable.
           (when (and definers (null (cdr definers))
                      (not (equal (car definers) file)))
             (let ((other (car definers)))
               (when (nl-ns--private-name-p (symbol-name sym))
                 (setq escapes (cons (cons sym other) escapes)))
               (puthash other t deps)))))
       symbols))
    (setq escapes
          (sort escapes
                (lambda (a b) (string< (symbol-name (car a))
                                       (symbol-name (car b))))))
    (dolist (escape escapes)
      (setq findings
            (cons (list :kind 'ns-private-escape
                        :subject (car escape) :file file
                        :owner (cdr escape))
                  findings)))
    (when check-deps
      (let ((targets nil))
        (maphash (lambda (other _v) (setq targets (cons other targets))) deps)
        (setq targets (sort targets #'string<))
        (dolist (other targets)
          (unless (nl-ns--requires-file-p entry other analysis)
            (setq findings
                  (cons (list :kind 'ns-undeclared-dependency
                              :subject other :file file)
                        findings))))))
    findings))

(defun nl-ns-check (analysis &optional check-dependencies)
  "Return the findings for ANALYSIS, in a stable order.
CHECK-DEPENDENCIES additionally reports `ns-undeclared-dependency'.
That check is off by default because a tree that has always relied on
load order produces one finding per edge of its real dependency graph;
turn it on when you are ready to read that graph."
  (let ((findings nil))
    (dolist (entry (plist-get analysis :files))
      (if (plist-get entry :unreadable)
          (setq findings
                (cons (list :kind 'ns-unreadable
                            :subject (plist-get entry :file)
                            :file (plist-get entry :file))
                      findings))
        (setq findings (nl-ns--check-prefixes entry findings))
        (setq findings
              (nl-ns--check-references entry analysis check-dependencies
                                       findings))))
    (setq findings (nl-ns--check-collisions analysis findings))
    (nreverse findings)))

(defun nl-ns-check-files (paths &optional check-dependencies)
  "Read PATHS and return their findings.  See `nl-ns-check'."
  (nl-ns-check (nl-ns-analyse-files paths) check-dependencies))

;;;; Reporting -----------------------------------------------------------

(defun nl-ns-findings-of-kind (findings kind)
  "Return the elements of FINDINGS whose `:kind' is KIND."
  (let ((out nil))
    (dolist (finding findings)
      (when (eq (plist-get finding :kind) kind)
        (setq out (cons finding out))))
    (nreverse out)))

(defun nl-ns--describe (finding)
  "Return a one-line description of FINDING."
  (let ((kind (plist-get finding :kind))
        (subject (plist-get finding :subject)))
    (cond
     ((eq kind 'ns-collision)
      (format "ns-collision: `%s' defined in %d files: %s"
              subject (plist-get finding :count)
              (mapconcat #'identity (plist-get finding :files) ", ")))
     ((eq kind 'ns-prefix-violation)
      (format "ns-prefix-violation: %s defines `%s', outside namespace `%s'"
              (plist-get finding :file) subject
              (plist-get finding :expected)))
     ((eq kind 'ns-private-escape)
      (format "ns-private-escape: %s references `%s', private to %s"
              (plist-get finding :file) subject (plist-get finding :owner)))
     ((eq kind 'ns-undeclared-dependency)
      (format "ns-undeclared-dependency: %s uses %s without requiring it"
              (plist-get finding :file) subject))
     ((eq kind 'ns-unreadable)
      (format "ns-unreadable: %s could not be read" subject))
     (t (format "%s: %s" kind subject)))))

(defun nl-ns-report (findings)
  "Return a human-readable report string for FINDINGS."
  (if (null findings)
      "nl-ns: no findings\n"
    (let ((lines nil))
      (dolist (finding findings)
        (setq lines (cons (concat "  " (nl-ns--describe finding) "\n")
                          lines)))
      (apply #'concat
             (format "nl-ns: %d finding(s)\n" (length findings))
             (nreverse lines)))))

(defun nl-ns-summary (findings)
  "Return an alist of (KIND . COUNT) for FINDINGS, most frequent first."
  (let ((counts nil))
    (dolist (finding findings)
      (let* ((kind (plist-get finding :kind))
             (cell (assq kind counts)))
        (if cell
            (setcdr cell (1+ (cdr cell)))
          (setq counts (cons (cons kind 1) counts)))))
    (sort counts (lambda (a b) (> (cdr a) (cdr b))))))

(provide 'nl-ns)

;;; nl-ns.el ends here
