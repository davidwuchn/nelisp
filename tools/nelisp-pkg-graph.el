;;; nelisp-pkg-graph.el --- report the package graph, fail on a cycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Derives the cross-package dependency graph from `provide' / `require'
;; and prints it, with a load order when one exists.
;;
;; Four findings fail the build:
;;
;;   pkg-cycle                 a ring of requires has no load order at
;;                             all, so no care at the call site can work
;;                             around it
;;   pkg-invalid-manifest      a manifest that cannot be read is worse
;;                             than none, because it is believed
;;   pkg-undeclared-dependency the code depends on a package the
;;                             manifest does not name
;;   pkg-stale-dependency      the manifest names one the code no longer
;;                             uses
;;
;; The last two became gateable once every package had a manifest
;; (2026-08-18).  They are the whole point of having manifests: without
;; them a declaration is decoration.  Both are fixed by one command --
;; `make pkg-manifest-update' -- so the gate costs a keystroke rather
;; than an editing chore, which is the difference between a rule people
;; keep and one they route around.
;;
;; `pkg-missing-manifest' and `pkg-unresolved-require' are reported and
;; not gated: the first cannot fire today, and the second is mostly host
;; Emacs libraries, which would make the check red from birth.

;;; Code:

(require 'nelisp-pkg)

(defun nelisp-pkg-graph-run ()
  "Print the package graph and exit non-zero on a structural failure."
  (let* ((packages (nelisp-pkg-scan))
         (core (nelisp-pkg-core-features))
         (findings (nelisp-pkg-check packages core))
         (edges (nelisp-pkg-edges packages))
         (resolution (nelisp-pkg-resolve packages))
         (fatal (append (nelisp-pkg-findings-of-kind findings 'pkg-cycle)
                        (nelisp-pkg-findings-of-kind findings
                                                     'pkg-invalid-manifest)
                        (nelisp-pkg-findings-of-kind findings
                                                     'pkg-undeclared-dependency)
                        (nelisp-pkg-findings-of-kind findings
                                                     'pkg-stale-dependency))))
    (princ (nelisp-pkg-report packages findings))
    (princ "\n  cross-package edges\n")
    (dolist (edge edges)
      (princ (format "    %s -> %s\n" (car edge) (cdr edge))))
    (let ((unresolved (nelisp-pkg-findings-of-kind findings
                                                   'pkg-unresolved-require)))
      (when unresolved
        (princ (format "\n  requires provided nowhere in the tree (%d), assumed host:\n"
                       (length unresolved)))
        (let ((names nil))
          (dolist (finding unresolved)
            (cl-pushnew (plist-get finding :feature) names))
          (princ (format "    %s\n"
                         (mapconcat #'symbol-name (sort names #'string<) " "))))))
    (when (plist-get resolution :order)
      (princ (format "\n  load order: %s\n"
                     (mapconcat #'identity (plist-get resolution :order) " "))))
    ;; Machine-readable tail (contract: tools/ai/README.md).  `checked'
    ;; counts packages, so a scan that found no packages -- wrong working
    ;; directory, renamed layout -- cannot read as a clean graph.
    (princ (format "GATE-COUNT checked=%d findings=%d\n"
                   (length packages) (length findings)))
    (dolist (finding fatal)
      (pcase (plist-get finding :kind)
        ('pkg-undeclared-dependency
         (princ (format "\n  UNDECLARED %s depends on %s\n"
                        (plist-get finding :subject)
                        (plist-get finding :dependency))))
        ('pkg-stale-dependency
         (princ (format "\n  STALE %s no longer uses %s\n"
                        (plist-get finding :subject)
                        (plist-get finding :dependency))))))
    (if fatal
        (progn
          (princ (format "pkg-graph: FAIL (%d finding(s))\n" (length fatal)))
          (when (or (nelisp-pkg-findings-of-kind findings
                                                'pkg-undeclared-dependency)
                    (nelisp-pkg-findings-of-kind findings
                                                 'pkg-stale-dependency))
            (princ "  fix with: make pkg-manifest-update\n"))
          (kill-emacs 1))
      (princ "pkg-graph: PASS\n"))))

(nelisp-pkg-graph-run)

;;; nelisp-pkg-graph.el ends here
