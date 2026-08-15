;;; cl-lib.el --- host-shadow fixture whose only warning is a comment -*- lexical-binding: t; -*-

;;; Commentary:

;; The partiality marker lives in a comment that a wrapper form has
;; pushed away from the top level, and the docstring says nothing about
;; it.  Finding the marker here is what proves the comment scan reaches
;; inside the wrapper.

;;; Code:

(when (or (not (boundp 'emacs-version))
          (my--define-p 'cl-loop))
  ;; Stub: minimal cl-loop supporting subset forms; returns nil for others.
  (defun cl-loop (&rest _spec)
    "Run the loop."
    nil))

(provide 'cl-lib)
;;; cl-lib.el ends here
