;;; nl-parens-check.el --- Batch gate for unbalanced Emacs Lisp parens -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'nl-parens)

(defun nl-parens-check--files-in (directory)
  "Return every Emacs Lisp file below DIRECTORY, or nil when it is absent."
  (if (file-directory-p directory)
      (directory-files-recursively directory "\\.el\\'")
    nil))

(let ((paths nil))
  (dolist (directory '("lisp" "src" "scripts"))
    (setq paths (append paths (nl-parens-check--files-in directory))))
  (dolist (package (directory-files "packages" t "\\`[^.]"))
    (setq paths (append paths (nl-parens-check--files-in
                               (expand-file-name "src" package))
                        (nl-parens-check--files-in
                         (expand-file-name "test" package)))))
  (let ((findings (nl-parens-check-files paths)))
    (princ (nl-parens-report findings))
    (when findings (kill-emacs 1))))

;;; nl-parens-check.el ends here
