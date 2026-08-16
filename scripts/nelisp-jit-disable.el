;;; nelisp-jit-disable.el --- run a suite with the JIT off  -*- lexical-binding: t; -*-

;;; Commentary:

;; `nelisp-jit-enabled' defaults to t as of 2026-08-16, so the ordinary
;; suite now exercises the JIT wherever `nelisp-bytecode' is loaded.
;; That is the point of the default, and it also means the bcl and
;; interpreter paths stop being covered unless something turns the JIT
;; back off.
;;
;; This is that something.  It is the mirror of
;; `scripts/nelisp-jit-enable.el', which existed while the default was
;; nil for exactly the same reason in the other direction: whichever way
;; the default points, the other path needs a run of its own or it rots.
;;
;; Usage:
;;   make test-nojit

;;; Code:

;; Runs before the Makefile's own `(setq load-prefer-newer t)'.
(setq load-prefer-newer t)

(dolist (dir '("lisp" "src" "packages/nelisp-jit/src"))
  (add-to-list 'load-path (expand-file-name dir)))

;; Set the variable before anything can load the package, so the value
;; below wins over the defvar's default rather than racing it.
(defvar nelisp-jit-enabled)
(setq nelisp-jit-enabled nil)

(princ "[jit-disable] nelisp-jit-enabled = nil for this run\n")

;;; nelisp-jit-disable.el ends here
