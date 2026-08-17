;;; nelisp-pkg-load-lists.el --- check hand-written load lists -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The standalone smokes and recipes load their dependencies by explicit
;; path, in an order someone worked out once:
;;
;;     (load "packages/nl-prelude/src/nl-prelude.el")
;;     (load "packages/nl-safe/src/nl-safe.el")
;;
;; Those lists cannot simply be replaced by a generated one -- generating
;; it inside the standalone runtime would mean bootstrapping nelisp-pkg
;; there first -- so this checks them instead, which is the half that
;; matters.  A stale list produces no message at all: `(load "missing.el"
;; nil t)' returns t in that runtime rather than signalling, so the
;; script runs to completion with nothing defined and the first symptom
;; is a `void-function' somewhere unrelated.
;;
;;     make pkg-load-lists
;;
;; Fails on a path that does not exist and on a file loaded before
;; something it requires.  Computed paths are counted and reported, so
;; "nothing was checked" cannot look like "everything passed".

;;; Code:

(require 'nelisp-pkg)

(defun nelisp-pkg-load-lists--files ()
  "Return the files that carry a hand-written load list."
  (let ((files nil))
    (dolist (dir (append (file-expand-wildcards "packages/*/test")
                         (file-expand-wildcards "recipes/*")))
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.el\\'"))
          (let ((calls (nelisp-pkg-load-list file)))
            (when calls (push file files))))))
    (sort files #'string<)))

(defun nelisp-pkg-load-lists-run ()
  "Check every hand-written load list and exit non-zero on a failure."
  (let ((root (expand-file-name default-directory))
        (files (nelisp-pkg-load-lists--files))
        (checked 0)
        (all nil))
    (dolist (file files)
      (let* ((result (nelisp-pkg-check-load-list file root))
             (findings (plist-get result :findings)))
        (setq checked (+ checked (plist-get result :checked)))
        (setq all (append all findings))
        (princ (format "%4d  %s\n"
                       (plist-get result :checked)
                       (file-relative-name file root)))
        (dolist (finding findings)
          (pcase (plist-get finding :kind)
            ('load-list-missing-file
             (princ (format "        MISSING %s\n" (plist-get finding :path))))
            ('load-list-out-of-order
             (princ (format "        OUT OF ORDER %s needs `%s' from %s\n"
                            (plist-get finding :path)
                            (plist-get finding :feature)
                            (plist-get finding :after))))
            ('load-list-computed-path
             (princ "        computed path, not checkable\n"))))))
    (princ (format "\npkg-load-lists: %d file(s), %d load(s) checked\n"
                   (length files) checked))
    ;; `checked' counts loads verified, not files visited: a scan that
    ;; found the files but no loads inside them must not read as clean.
    (princ (format "GATE-COUNT checked=%d findings=%d\n" checked (length all)))
    (let ((fatal (cl-remove-if-not
                  (lambda (f) (memq (plist-get f :kind)
                                    '(load-list-missing-file
                                      load-list-out-of-order)))
                  all)))
      (if fatal
          (progn
            (princ (format "pkg-load-lists: FAIL (%d broken list(s))\n"
                           (length fatal)))
            (kill-emacs 1))
        (princ "pkg-load-lists: PASS\n")))))

(nelisp-pkg-load-lists-run)

;;; nelisp-pkg-load-lists.el ends here
