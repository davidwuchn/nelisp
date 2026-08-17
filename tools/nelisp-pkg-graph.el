;;; nelisp-pkg-graph.el --- report the package graph, fail on a cycle -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Derives the cross-package dependency graph from `provide' / `require'
;; and prints it, with a load order when one exists.
;;
;; Only two findings fail the build, and both are structural:
;;
;;   pkg-cycle            a ring of requires has no load order at all,
;;                        so no care at the call site can work around it
;;   pkg-invalid-manifest a manifest that cannot be read is worse than
;;                        none, because it is believed
;;
;; The rest are reported and not gated.  `pkg-missing-manifest' fires
;; for every package until manifests are adopted, and
;; `pkg-unresolved-require' is mostly host Emacs libraries; gating on
;; either would make the check red from birth, which is how a gate
;; becomes decoration.

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
                                                     'pkg-invalid-manifest))))
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
    (if fatal
        (progn
          (princ (format "pkg-graph: FAIL (%d structural finding(s))\n"
                         (length fatal)))
          (kill-emacs 1))
      (princ "pkg-graph: PASS\n"))))

(nelisp-pkg-graph-run)

;;; nelisp-pkg-graph.el ends here
