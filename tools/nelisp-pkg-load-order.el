;;; nelisp-pkg-load-order.el --- print a package's load sequence -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Prints, one per line, the files to load for a package and everything
;; it depends on, in an order where each file follows what it needs.
;;
;;   make pkg-load-order PKG=nl-safe
;;
;; This is for the standalone runtime, where dependencies are loaded by
;; explicit path rather than through `require'.  Every smoke and recipe
;; that does so currently carries a hand-written list in a hand-worked-out
;; order; add a dependency and each of those lists is silently wrong
;; until someone runs it.  The order is derivable from the same data as
;; the package graph, so derive it:
;;
;;   for f in $(make -s pkg-load-order PKG=nl-safe); do ... ; done
;;
;; Paths are printed relative to the repository root, because that is
;; what the runtime resolves them against.

;;; Code:

(require 'nelisp-pkg)

(defun nelisp-pkg-load-order-run ()
  "Print the load sequence for the package named by PKG."
  (let ((name (getenv "PKG")))
    (unless (and name (> (length name) 0))
      (princ "usage: make pkg-load-order PKG=<package>\n")
      (kill-emacs 2))
    ;; Emit LF, not CRLF.  On Windows the default terminal coding system
    ;; turns every newline into CRLF, and the caller is a shell loop:
    ;;
    ;;   for f in $(make -s pkg-load-order PKG=nl-safe); do ...
    ;;
    ;; which keeps the carriage return as part of the path.  The load
    ;; then silently does nothing -- `load' on a missing file returns t
    ;; here even with NOERROR nil -- so the whole sequence appears to run
    ;; and nothing is defined.  Measured; it cost an hour to find.
    (when (fboundp 'set-binary-mode)
      (set-binary-mode 'stdout t))
    (set-terminal-coding-system 'utf-8-unix)
    (let* ((packages (nelisp-pkg-scan))
           (root (expand-file-name default-directory))
           (sequence (nelisp-pkg-load-sequence name packages)))
      (dolist (file sequence)
        (princ (format "%s\n" (file-relative-name file root))))
      (kill-emacs 0))))

(nelisp-pkg-load-order-run)

;;; nelisp-pkg-load-order.el ends here
