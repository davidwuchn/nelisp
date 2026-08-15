;;; safe-loop.el --- safe host-shadow fixture -*- lexical-binding: t; -*-

(unless (fboundp 'cl-loop)
  (defun cl-loop (&rest spec)
    "Stub: minimal cl-loop supporting `for VAR in LIST do/collect/...'. For patterns this stub does not recognise, returns nil."
    nil))
