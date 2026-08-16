;;; nelisp-jit-enable.el --- run a suite with the JIT on  -*- lexical-binding: t; -*-

;;; Commentary:

;; `nelisp-jit-enabled' is nil by default, and the only places that bind
;; it are two of the JIT's own tests.  So the JIT translates a handful of
;; bodies during a full run and nothing else ever goes through it: a
;; whole translation path, exercised by the tests that were written for
;; it and by nothing that uses it.
;;
;; Preloading this turns it on for the run, so every closure the suite
;; builds goes through the JIT and falls back to bcl / interpreter where
;; the JIT declines.  That is the coverage question -- does real code
;; survive the JIT -- rather than the measurement question, which
;; `scripts/nelisp-jit-unverified.el' answers and which costs an
;; `nl-check' walk of every body.  This one adds no per-body work.
;;
;; Usage:
;;   make test-jit

;;; Code:

;; This preload runs before the Makefile's own
;; `(setq load-prefer-newer t)', so without setting it here the require
;; below can pick up a stale .elc.
(setq load-prefer-newer t)

(dolist (dir '("lisp" "src" "packages/nelisp-jit/src"))
  (add-to-list 'load-path (expand-file-name dir)))

(require 'nelisp-jit nil t)

(if (boundp 'nelisp-jit-enabled)
    (progn
      (setq nelisp-jit-enabled t)
      (when (fboundp 'nelisp-jit-install)
        (nelisp-jit-install))
      (princ "[jit-enable] nelisp-jit-enabled = t for this run\n"))
  (princ "[jit-enable] nelisp-jit not available; running without it\n"))

;;; nelisp-jit-enable.el ends here
