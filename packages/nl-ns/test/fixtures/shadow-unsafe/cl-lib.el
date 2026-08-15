;;; cl-lib.el --- unsafe host-shadow fixture -*- lexical-binding: t; -*-

;; Stub: minimal cl-loop supporting `for VAR in LIST do/collect/...'.
;; For patterns this stub does not recognise, returns nil.
(when (or (not (boundp 'emacs-version))
          (my--define-p 'cl-loop)
          (autoloadp (symbol-function 'cl-loop)))
  (defun cl-loop (&rest spec)
    "Stub: minimal cl-loop supporting `for VAR in LIST do/collect/...'. For patterns this stub does not recognise, returns nil."
    nil))
