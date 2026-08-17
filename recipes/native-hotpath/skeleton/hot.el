;;; hot.el --- a function worth compiling natively -*- lexical-binding: t; -*-

;;; Commentary:

;; The unit of native compilation is a file: `compile-elisp-artifact'
;; turns one `.el' into one `.neln' plus a manifest, and the manifest
;; says, per function, whether it actually went native.  So the shape of
;; a hot path is a small file containing only the functions you want
;; compiled, required from the rest of your program as usual.
;;
;;     nelisp compile-elisp-artifact --kind neln \
;;       --input hot.el --output hot.neln
;;     nelisp inspect-elisp-artifact hot.neln
;;
;; Keep the arithmetic integer here.  Floating point has its own rules
;; (f64 arithmetic is x86_64 only, extern-call caps at 8 f64 arguments)
;; and libc-dependent code becomes a link-time dependency rather than a
;; self-contained artifact.  `docs/runtime-limitations.md' is the list;
;; read it before assuming a function behaves like its C equivalent.

;;; Code:

(defun hot-sum-to (n)
  "Return the sum of the integers from 1 to N."
  (let ((acc 0)
        (i 1))
    (while (<= i n)
      (setq acc (+ acc i))
      (setq i (+ i 1)))
    acc))

(defun hot-checksum (n seed)
  "Fold SEED over the integers from 1 to N.
A second definition, so that the manifest's per-function report has
more than one row to be right about."
  (let ((acc seed)
        (i 1))
    (while (<= i n)
      (setq acc (+ (* acc 31) i))
      (setq i (+ i 1)))
    acc))

(provide 'hot)

;;; hot.el ends here
