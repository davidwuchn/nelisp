;;; nelisp-pkg-manifest.el --- write package manifests from the real graph -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Writes `packages/<name>/manifest.el' with the dependencies the code
;; actually has.
;;
;;     make pkg-manifest-update            # every package
;;     make pkg-manifest-update PKG=nl-safe
;;
;; This exists so that fixing a `pkg-undeclared-dependency' finding is
;; one command rather than an editing chore.  A declaration people have
;; to maintain by hand is a declaration that goes stale, and the gate
;; that notices would then be pure friction.
;;
;; Keys other than `:name' and `:requires' are preserved: regenerating
;; dependencies must never silently drop a `:version' or anything else
;; an author added.
;;
;; `:version' is not written.  Nothing consumes one yet, and stamping 34
;; invented numbers into the tree would be metadata in appearance only.

;;; Code:

(require 'nelisp-pkg)

(defun nelisp-pkg-manifest-run ()
  "Write manifests for every package, or for PKG when set."
  (when (fboundp 'set-binary-mode)
    (set-binary-mode 'stdout t))
  (let* ((only (let ((raw (getenv "PKG"))) (and raw (> (length raw) 0) raw)))
         (packages (nelisp-pkg-scan))
         (root (expand-file-name default-directory))
         (written 0)
         (unchanged 0))
    (dolist (package packages)
      (let ((name (plist-get package :name)))
        (when (or (null only) (equal only name))
          (let* ((requires (nelisp-pkg-actual-requires package packages))
                 (file (expand-file-name "manifest.el" (plist-get package :dir)))
                 (text (nelisp-pkg-manifest-render
                        name requires (plist-get package :manifest)))
                 (current (and (file-readable-p file)
                               (with-temp-buffer
                                 (insert-file-contents file)
                                 (buffer-string)))))
            (if (equal current text)
                (setq unchanged (1+ unchanged))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file file (insert text)))
              (setq written (1+ written))
              (princ (format "wrote %s (%s)\n"
                             (file-relative-name file root)
                             (if requires
                                 (mapconcat #'identity requires " ")
                               "no package dependencies"))))))))
    (princ (format "pkg-manifest: %d written, %d already correct\n"
                   written unchanged))))

(nelisp-pkg-manifest-run)

;;; nelisp-pkg-manifest.el ends here
