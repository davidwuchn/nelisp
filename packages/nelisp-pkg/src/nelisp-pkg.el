;;; nelisp-pkg.el --- package manifests checked against the real graph -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; NeLisp has packages but no package system.  `packages/<name>/' is a
;; layout convention, the Makefile puts every `src' directory on the load
;; path, and `require' finds whatever is there.  That works until two
;; questions need answering: what does this package depend on, and in
;; what order may these be loaded.  Neither is written down anywhere
;; today, so both are answered by trying it.
;;
;; This library derives the answer from the code and lets a package
;; declare it, then checks the declaration against the derivation.  The
;; derivation is the source of truth about what the code does; the
;; manifest is a statement of intent, and the interesting output is
;; where the two disagree.
;;
;; Deriving first is deliberate.  A manifest format adopted before the
;; graph is known would be 34 files of guesses, and a package system
;; whose metadata is unverified is a package system that lies -- which
;; is worse than none, because it is believed.
;;
;; A manifest is a plist in `packages/<name>/manifest.el':
;;
;;     (:name "nelisp-http"
;;      :version "1.0"
;;      :requires ("nelisp-process" "nelisp-state" "nelisp-sys"))
;;
;; Findings use the same shape as `nl-check' and `nl-ns':
;; `(:kind KIND :subject S ...)'.
;;
;; | kind                       | meaning                                    |
;; |----------------------------+--------------------------------------------|
;; | pkg-cycle                  | packages that require each other in a ring |
;; | pkg-undeclared-dependency  | the code requires it, the manifest does not|
;; | pkg-stale-dependency       | the manifest requires it, the code does not|
;; | pkg-missing-manifest       | no manifest.el (informational for now)     |
;; | pkg-invalid-manifest       | manifest.el is unreadable or malformed     |
;; | pkg-unresolved-require     | required feature provided nowhere in tree  |
;;
;; `pkg-unresolved-require' is the low-severity carrier: a require that
;; nothing in the tree provides is usually a host Emacs library
;; (`cl-lib', `dom') or a runtime builtin, not an error.  It is reported
;; so that an unexpected one is visible, not to be driven to zero.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;;; Reading -------------------------------------------------------------

(defun nelisp-pkg--read-forms (file)
  "Return every top-level form in FILE, or nil when it cannot be read."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((forms nil))
          (condition-case nil
              (while t (push (read (current-buffer)) forms))
            (end-of-file nil))
          (nreverse forms)))
    (error nil)))

(defun nelisp-pkg--walk (form fn)
  "Call FN on every cons cell in FORM.

The spine is walked iteratively and only the cars are recursed into,
for two reasons.  Source files contain dotted pairs -- alist literals
like `(let . bindings-and-body)' are everywhere in this tree -- so a
`dolist' over a form is wrong the moment it meets one.  And a long data
literal is a long spine, which recursion down the cdr would turn into
stack depth."
  (let ((tail form))
    (while (consp tail)
      (funcall fn tail)
      (when (consp (car tail))
        (nelisp-pkg--walk (car tail) fn))
      (setq tail (cdr tail)))))

(defun nelisp-pkg--feature-arg (form head)
  "Return the feature symbol when FORM is (HEAD \\='FEATURE ...).
Only a quoted literal counts: a computed feature name is not a
dependency anyone can resolve statically, and pretending otherwise
would put a guess into the graph."
  (when (and (consp form)
             (eq (car form) head)
             (consp (cdr form)))
    (let ((arg (nth 1 form)))
      (cond
       ((and (consp arg) (eq (car arg) 'quote) (symbolp (nth 1 arg)))
        (nth 1 arg))
       ((symbolp arg) nil)))))

(defun nelisp-pkg-file-features (file)
  "Return (PROVIDES . REQUIRES) for FILE, each a list of symbols."
  (let ((provides nil)
        (requires nil))
    (dolist (form (nelisp-pkg--read-forms file))
      (nelisp-pkg--walk
       form
       (lambda (node)
         (let ((p (nelisp-pkg--feature-arg node 'provide))
               (r (nelisp-pkg--feature-arg node 'require)))
           (when p (cl-pushnew p provides))
           (when r (cl-pushnew r requires))))))
    (cons (nreverse provides) (nreverse requires))))

;;;; Manifests -----------------------------------------------------------

(defconst nelisp-pkg-manifest-keys '(:name :version :requires)
  "Keys a manifest must carry.")

(defun nelisp-pkg-validate-manifest (manifest)
  "Return a list of problem strings for MANIFEST, empty when it is valid."
  (let ((problems nil))
    (if (not (and manifest (listp manifest)))
        (push "manifest is not a plist" problems)
      (dolist (key nelisp-pkg-manifest-keys)
        (unless (plist-member manifest key)
          (push (format "missing %s" key) problems)))
      (let ((name (plist-get manifest :name))
            (version (plist-get manifest :version))
            (requires (plist-get manifest :requires)))
        (unless (stringp name) (push ":name must be a string" problems))
        (unless (stringp version) (push ":version must be a string" problems))
        (unless (listp requires) (push ":requires must be a list" problems))
        (dolist (r (and (listp requires) requires))
          (unless (stringp r)
            (push (format ":requires entry %S must be a string" r) problems)))))
    (nreverse problems)))

(defun nelisp-pkg-read-manifest (dir)
  "Return (MANIFEST . PROBLEMS) for DIR, or nil when it has no manifest."
  (let ((file (expand-file-name "manifest.el" dir)))
    (when (file-readable-p file)
      (let ((forms (nelisp-pkg--read-forms file)))
        (if (null forms)
            (cons nil (list "manifest.el could not be read"))
          (let ((manifest (car forms)))
            (cons manifest (nelisp-pkg-validate-manifest manifest))))))))

;;;; Scanning ------------------------------------------------------------

(defun nelisp-pkg-scan-package (dir)
  "Return a plist describing the package rooted at DIR."
  (let* ((name (file-name-nondirectory (directory-file-name dir)))
         (src (expand-file-name "src" dir))
         (files (and (file-directory-p src)
                     (directory-files src t "\\.el\\'")))
         (provides nil)
         (requires nil))
    (dolist (file files)
      (let ((pair (nelisp-pkg-file-features file)))
        (dolist (p (car pair)) (cl-pushnew p provides))
        (dolist (r (cdr pair)) (cl-pushnew r requires))))
    (let ((manifest (nelisp-pkg-read-manifest dir)))
      (list :name name
            :dir dir
            :files (length files)
            :provides (nreverse provides)
            :requires (nreverse requires)
            :manifest (car manifest)
            :manifest-problems (cdr manifest)
            :has-manifest (and manifest t)))))

(defun nelisp-pkg-scan (&optional root)
  "Scan `packages/' below ROOT (default `default-directory')."
  (let* ((base (expand-file-name "packages" (or root default-directory)))
         (dirs (and (file-directory-p base)
                    (cl-remove-if-not #'file-directory-p
                                      (directory-files base t "\\`[^.]")))))
    (mapcar #'nelisp-pkg-scan-package dirs)))

(defun nelisp-pkg-core-features (&optional root dirs)
  "Return the features provided outside `packages/'.
DIRS defaults to src and lisp below ROOT."
  (let ((features nil))
    (dolist (dir (or dirs '("src" "lisp")))
      (let ((full (expand-file-name dir (or root default-directory))))
        (when (file-directory-p full)
          (dolist (file (directory-files full t "\\.el\\'"))
            (dolist (p (car (nelisp-pkg-file-features file)))
              (cl-pushnew p features))))))
    features))

;;;; The graph -----------------------------------------------------------

(defun nelisp-pkg-provider-table (packages)
  "Return a hash of FEATURE -> package name for PACKAGES."
  (let ((table (make-hash-table :test #'eq)))
    (dolist (package packages)
      (dolist (feature (plist-get package :provides))
        (puthash feature (plist-get package :name) table)))
    table))

(defun nelisp-pkg-edges (packages)
  "Return ((FROM . TO) ...) for cross-package requires in PACKAGES."
  (let ((providers (nelisp-pkg-provider-table packages))
        (edges nil))
    (dolist (package packages)
      (let ((from (plist-get package :name)))
        (dolist (feature (plist-get package :requires))
          (let ((to (gethash feature providers)))
            (when (and to (not (equal to from)))
              (cl-pushnew (cons from to) edges :test #'equal))))))
    (nreverse edges)))

(defun nelisp-pkg-resolve (packages)
  "Return (:order NAMES :cycles NAMES) for PACKAGES.

The order is a load order: every package appears after the ones it
requires.  Names that could not be ordered are returned as `:cycles',
which is the only structural failure this library treats as fatal --
a ring of requires has no load order at all, so no amount of care at
the call site can work around it."
  (let* ((edges (nelisp-pkg-edges packages))
         (names (mapcar (lambda (p) (plist-get p :name)) packages))
         (pending (copy-sequence names))
         (order nil)
         (progress t))
    (while (and pending progress)
      (setq progress nil)
      (dolist (name (copy-sequence pending))
        (let ((deps (cl-remove-if-not
                     (lambda (edge) (equal (car edge) name))
                     edges)))
          (when (cl-every (lambda (edge) (member (cdr edge) order))
                          deps)
            (setq order (append order (list name)))
            (setq pending (delete name pending))
            (setq progress t)))))
    (list :order order :cycles pending)))

;;;; Checking ------------------------------------------------------------

(defun nelisp-pkg-check (packages &optional core-features)
  "Return findings for PACKAGES, given CORE-FEATURES from outside packages/."
  (let* ((providers (nelisp-pkg-provider-table packages))
         (resolution (nelisp-pkg-resolve packages))
         (findings nil))
    (dolist (name (plist-get resolution :cycles))
      (push (list :kind 'pkg-cycle :subject name) findings))
    (dolist (package packages)
      (let* ((name (plist-get package :name))
             (declared (plist-get (plist-get package :manifest) :requires))
             (actual (delete-dups
                      (delq nil
                            (mapcar (lambda (feature)
                                      (let ((owner (gethash feature providers)))
                                        (and owner (not (equal owner name)) owner)))
                                    (plist-get package :requires))))))
        (dolist (problem (plist-get package :manifest-problems))
          (push (list :kind 'pkg-invalid-manifest :subject name :detail problem)
                findings))
        (if (not (plist-get package :has-manifest))
            (push (list :kind 'pkg-missing-manifest :subject name) findings)
          (dolist (dep actual)
            (unless (member dep declared)
              (push (list :kind 'pkg-undeclared-dependency
                          :subject name :dependency dep)
                    findings)))
          (dolist (dep declared)
            (unless (member dep actual)
              (push (list :kind 'pkg-stale-dependency
                          :subject name :dependency dep)
                    findings))))
        (dolist (feature (plist-get package :requires))
          (unless (or (gethash feature providers)
                      (memq feature core-features)
                      (memq feature (plist-get package :provides)))
            (push (list :kind 'pkg-unresolved-require
                        :subject name :feature feature)
                  findings)))))
    (nreverse findings)))

(defun nelisp-pkg-findings-of-kind (findings kind)
  "Return the FINDINGS whose `:kind' is KIND."
  (cl-remove-if-not (lambda (f) (eq (plist-get f :kind) kind)) findings))

(defun nelisp-pkg-summary (findings)
  "Return ((KIND . COUNT) ...) for FINDINGS, most frequent first."
  (let ((table (make-hash-table :test #'eq))
        (rows nil))
    (dolist (finding findings)
      (let ((kind (plist-get finding :kind)))
        (puthash kind (1+ (gethash kind table 0)) table)))
    (maphash (lambda (k v) (push (cons k v) rows)) table)
    (sort rows (lambda (a b) (> (cdr a) (cdr b))))))

(defun nelisp-pkg-report (packages findings)
  "Return a human-readable report string."
  (let ((resolution (nelisp-pkg-resolve packages))
        (edges (nelisp-pkg-edges packages)))
    (concat
     (format "nelisp-pkg: %d package(s), %d cross-package edge(s)\n"
             (length packages) (length edges))
     (mapconcat (lambda (row) (format "%6d  %s\n" (cdr row) (car row)))
                (nelisp-pkg-summary findings)
                "")
     (if (plist-get resolution :cycles)
         (format "  CYCLE: %s\n"
                 (mapconcat #'identity (plist-get resolution :cycles) ", "))
       ""))))

(provide 'nelisp-pkg)

;;; nelisp-pkg.el ends here
