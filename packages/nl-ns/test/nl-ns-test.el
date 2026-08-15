;;; nl-ns-test.el --- ERT tests for nl-ns -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-ns.el': namespace inference (including the
;; deliberately-global opt-out), collision detection, prefix violations,
;; private escapes, undeclared dependencies, and reporting.
;;
;; The tests feed already-read forms to `nl-ns-analyse' rather than
;; touching the filesystem, so the same bodies run on `target/nelisp'
;; through `test/nl-ns-standalone-smoke.el'.  No cl-lib, no ert-x.

;;; Code:

(require 'ert)
(require 'nl-ns)

;;; Helpers ------------------------------------------------------------

(defconst nl-ns-test--package-root-directory
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Package root, resolved while this file is being loaded.
`load-file-name' is bound during load and nil by the time a test body
runs, so resolving it on demand yields nil and every path built from
it fails with `wrong-type-argument stringp nil'.")

(defun nl-ns-test--package-root ()
  "Return the package root directory."
  nl-ns-test--package-root-directory)

(defun nl-ns-test--baseline-file ()
  "Return the checked-in baseline path."
  (expand-file-name "baseline/emacs-30.1.el" (nl-ns-test--package-root)))

(defun nl-ns-test--mini-baseline ()
  "Return a tiny in-memory baseline for host-shadow tests."
  (list :source "test baseline"
        :emacs-version "30.1"
        :generated-at "2026-08-15"
        :functions (nl-ns--list-to-set '(cl-loop))
        :variables (nl-ns--list-to-set '(emacs-version))
        :libraries (nl-ns--list-to-set '("cl-lib"))))

(defun nl-ns-test--fixture (&rest parts)
  "Return fixture path under test/fixtures."
  (let ((path (expand-file-name "test/fixtures" (nl-ns-test--package-root))))
    (while parts
      (setq path (expand-file-name (car parts) path))
      (setq parts (cdr parts)))
    path))

(defun nl-ns-test--check (entries &optional deps baseline)
  "Analyse ENTRIES and return the findings."
  (nl-ns-clear-declarations)
  (nl-ns-check (nl-ns-analyse entries) deps baseline))

(defun nl-ns-test--check-files (paths &optional deps baseline)
  "Read PATHS and return findings."
  (nl-ns-clear-declarations)
  (nl-ns-check-files paths deps baseline))

(defun nl-ns-test--kinds (entries &optional deps)
  "Return the finding kinds for ENTRIES, in order."
  (let ((kinds nil))
    (dolist (finding (nl-ns-test--check entries deps))
      (setq kinds (cons (plist-get finding :kind) kinds)))
    (nreverse kinds)))

;;; Reading and scanning -----------------------------------------------

(ert-deftest nl-ns-scan-collects-definitions ()
  (let ((scan (nl-ns-scan-forms
               '((defun foo-a () 1)
                 (defmacro foo-b () 2)
                 (defalias 'foo-c 'foo-a)
                 (defvar foo-d nil)))))
    (should (equal (plist-get scan :defines) '(foo-a foo-b foo-c foo-d)))))

(ert-deftest nl-ns-scan-collects-require-and-provide ()
  (let ((scan (nl-ns-scan-forms
               '((require 'other) (require 'third) (provide 'mine)))))
    (should (equal (plist-get scan :requires) '(other third)))
    (should (equal (plist-get scan :provides) '(mine)))))

(ert-deftest nl-ns-scan-collects-referenced-symbols ()
  (let ((scan (nl-ns-scan-forms '((defun foo-a () (bar-b (baz-c)))))))
    (should (gethash 'bar-b (plist-get scan :symbols)))
    (should (gethash 'baz-c (plist-get scan :symbols)))
    (should-not (gethash 'nowhere (plist-get scan :symbols)))))

(ert-deftest nl-ns-scan-ignores-non-definitions ()
  (let ((scan (nl-ns-scan-forms '((message "hi") (setq x 1)))))
    (should-not (plist-get scan :defines))))

(ert-deftest nl-ns-scan-expands-ns-in-definitions-without-evaluation ()
  (let ((scan (nl-ns-scan-forms
               '((nl-ns-define text :members (limit wrap chunk))
                 (nl-ns-in text
                   (defvar limit 80)
                   (defun wrap (s) (chunk s limit))
                   (defun chunk (s) s))))))
    (should (equal (plist-get scan :defines)
                   '(text-limit text-wrap text-chunk)))))

(ert-deftest nl-ns-scan-honors-ns-prefix ()
  (let ((scan (nl-ns-scan-forms
               '((nl-ns-define text :prefix "t/" :members (wrap))
                 (nl-ns-in text (defun wrap () 1))))))
    (should (equal (plist-get scan :defines) '(t/wrap)))))

;;; Namespace inference -------------------------------------------------

(ert-deftest nl-ns-infers-dominant-prefix ()
  (nl-ns-clear-declarations)
  (should (equal (nl-ns-file-namespace
                  "a.el" '(nl-safe-one nl-safe-two nl-safe-three))
                 "nl-safe-")))

(ert-deftest nl-ns-infers-longest-majority-prefix ()
  (nl-ns-clear-declarations)
  ;; Both "nl-" and "nl-safe-" cover the majority; the longer wins.
  (should (equal (nl-ns-file-namespace
                  "a.el" '(nl-safe-one nl-safe-two nl-other))
                 "nl-safe-")))

(ert-deftest nl-ns-no-dominant-prefix-opts-out ()
  (nl-ns-clear-declarations)
  ;; A deliberately global file (a stdlib prelude) has no majority
  ;; prefix and must not be prefix-checked at all.
  (should-not (nl-ns-file-namespace "a.el" '(car cdr princ terpri))))

(ert-deftest nl-ns-empty-file-has-no-namespace ()
  (nl-ns-clear-declarations)
  (should-not (nl-ns-file-namespace "a.el" nil)))

(ert-deftest nl-ns-declaration-overrides-inference ()
  (nl-ns-clear-declarations)
  (nl-ns-declare "a.el" "custom-")
  (should (equal (nl-ns-file-namespace "a.el" '(nl-safe-one nl-safe-two))
                 "custom-"))
  (nl-ns-clear-declarations)
  (should (equal (nl-ns-file-namespace "a.el" '(nl-safe-one nl-safe-two))
                 "nl-safe-")))

(ert-deftest nl-ns-declare-rejects-non-strings ()
  (should-error (nl-ns-declare 'a "x-"))
  (should-error (nl-ns-declare "a.el" 'x)))

;;; Collisions ----------------------------------------------------------

(ert-deftest nl-ns-collision-across-files ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defun eql (a b) (eq a b)))
                     ("b.el" (defun eql (a b) (eq a b)))))))
    (should (= (length findings) 1))
    (let ((finding (car findings)))
      (should (eq (plist-get finding :kind) 'ns-collision))
      (should (eq (plist-get finding :subject) 'eql))
      (should (= (plist-get finding :count) 2))
      (should (equal (plist-get finding :files) '("a.el" "b.el"))))))

(ert-deftest nl-ns-collision-divergent-replaces-plain-collision ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defun eql (a b) (eq a b)))
                     ("b.el" (defun eql (a b) (equal a b)))))))
    (should (= (length (nl-ns-findings-of-kind
                        findings 'ns-collision-divergent)) 1))
    (should-not (nl-ns-findings-of-kind findings 'ns-collision))))

(ert-deftest nl-ns-collision-docstring-difference-is-not-divergent ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defun eql (a b) "First wording." (eq a b)))
                     ("b.el" (defun eql (a b) "Second wording." (eq a b)))))))
    (should (= (length (nl-ns-findings-of-kind findings 'ns-collision)) 1))
    (should-not (nl-ns-findings-of-kind findings 'ns-collision-divergent))))

(ert-deftest nl-ns-collision-backquote-reader-spellings-agree ()
  (let ((findings (nl-ns-test--check
                   (list
                    (list "a.el"
                          (list 'defun 'eql '(x)
                                (list '\` (list 'value (list '\, 'x)))))
                    (list "b.el"
                          (list 'defun 'eql '(x)
                                (list 'backquote
                                      (list 'value (list 'comma 'x)))))))))
    (should (= (length (nl-ns-findings-of-kind findings 'ns-collision)) 1))
    (should-not (nl-ns-findings-of-kind findings 'ns-collision-divergent))))

(ert-deftest nl-ns-collision-divergent-records-definition-heads ()
  (let ((finding (car (nl-ns-findings-of-kind
                       (nl-ns-test--check
                        '(("a.el" (defalias 'eql 'equal))
                          ("b.el" (defun eql (a b) (eq a b)))))
                       'ns-collision-divergent))))
    (should (equal (plist-get finding :heads)
                   '(("a.el" . defalias) ("b.el" . defun))))))

(ert-deftest nl-ns-collision-divergent-finds-conditional-definition ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defalias 'eql 'equal))
                     ("b.el" (unless (fboundp 'eql)
                               (defun eql (a b) (eq a b))))))))
    (should (= (length (nl-ns-findings-of-kind
                        findings 'ns-collision-divergent)) 1))))

;;; Host shadow baseline findings --------------------------------------

(ert-deftest nl-ns-host-shadow-findings-need-a-baseline ()
  (let ((findings (nl-ns-test--check
                   '(("cl-lib.el"
                      (defun cl-loop (&rest forms)
                        "Stub: minimal cl-loop supporting subset forms; returns nil for others."
                        nil))))))
    (should-not (nl-ns-findings-of-kind findings 'ns-shadows-host))
    (should-not (nl-ns-findings-of-kind findings 'ns-partial-override))
    (should-not (nl-ns-findings-of-kind findings 'ns-unsafe-shim-guard))
    (should-not (nl-ns-findings-of-kind findings 'ns-file-shadows-library))))

(ert-deftest nl-ns-host-shadow-unsafe-fixture-fires-all-four-findings ()
  (let* ((baseline (nl-ns-test--baseline-file))
         (findings
          (nl-ns-test--check-files
           (list (nl-ns-test--fixture "shadow-unsafe" "cl-lib.el"))
           nil baseline)))
    (should (equal (mapcar #'nl-ns--finding-severity findings) '(1 2 3 6)))
    (should (equal (mapcar (lambda (finding) (plist-get finding :kind)) findings)
                   '(ns-partial-override ns-unsafe-shim-guard
                     ns-file-shadows-library ns-shadows-host)))
    (let ((partial (car findings)))
      (should (eq (plist-get partial :subject) 'cl-loop))
      ;; The docstring carries several markers; the reported one is the
      ;; first marker of the first sentence that has any, so it is
      ;; "minimal" rather than the "returns nil" further along.
      (should (equal (plist-get partial :marker) "minimal"))
      (should (string-match "Stub: minimal cl-loop" (plist-get partial :sentence))))
    (let ((guard (car (cdr findings))))
      (should (eq (plist-get guard :guard-kind) 'custom))
      (should (plist-get guard :autoloadp))
      (should (string-match "autoloadp" (plist-get guard :guard-source))))
    (should (= (nl-ns-report-max-severity findings) 1))))

(ert-deftest nl-ns-host-shadow-safe-fixture-stays-at-severity-six ()
  (let* ((baseline (nl-ns-test--baseline-file))
         (findings
          (nl-ns-test--check-files
           (list (nl-ns-test--fixture "shadow-safe" "safe-loop.el"))
           nil baseline)))
    (should (equal (mapcar (lambda (finding) (plist-get finding :kind)) findings)
                   '(ns-shadows-host)))
    (should (= (nl-ns-report-max-severity findings) 6))))

(ert-deftest nl-ns-host-shadow-comment-inside-wrapper-counts-as-partial-evidence ()
  "A marker in a comment must count even when the docstring is silent.
The fixture's warning sits in a comment that a `when' wrapper has
pushed away from the top level, which is where real shims put it, and
its docstring says nothing about being partial.  Reading a file rather
than hand-building analyser records is deliberate: the hand-built
version of this test passed metadata the analyser never produces and
so proved nothing about the real path."
  (let* ((baseline (nl-ns-test--baseline-file))
         (findings
          (nl-ns-test--check-files
           (list (nl-ns-test--fixture "shadow-comment" "cl-lib.el"))
           nil baseline)))
    (should (equal (mapcar (lambda (finding) (plist-get finding :kind)) findings)
                   '(ns-partial-override ns-unsafe-shim-guard
                     ns-file-shadows-library ns-shadows-host)))
    (let ((partial (car findings)))
      (should (eq (plist-get partial :subject) 'cl-loop))
      (should (equal (plist-get partial :marker) "returns nil"))
      (should (string-match "returns nil for others"
                            (plist-get partial :sentence))))))

(ert-deftest nl-ns-load-baseline-reads-metadata ()
  (let ((baseline (nl-ns-load-baseline (nl-ns-test--baseline-file))))
    (should (equal (plist-get baseline :emacs-version) "30.1"))
    (should (equal (plist-get baseline :generated-at) "2026-08-15"))
    (should (gethash 'cl-loop (plist-get baseline :functions)))
    (should (gethash 'emacs-version (plist-get baseline :variables)))
    (should (gethash "cl-lib" (plist-get baseline :libraries)))))

(ert-deftest nl-ns-collision-divergent-with-three-definers ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defun eql (a b) (eq a b)))
                     ("b.el" (defun eql (a b) (eq a b)))
                     ("c.el" (defun eql (a b) (equal a b)))))))
    (should (= (length (nl-ns-findings-of-kind
                        findings 'ns-collision-divergent)) 1))
    (should-not (nl-ns-findings-of-kind findings 'ns-collision))))

(ert-deftest nl-ns-collision-counts-every-definer ()
  (let ((finding (car (nl-ns-test--check
                       '(("a.el" (defun push () 1))
                         ("b.el" (defun push () 1))
                         ("c.el" (defun push () 1)))))))
    (should (= (plist-get finding :count) 3))))

(ert-deftest nl-ns-single-definition-is-not-a-collision ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check '(("a.el" (defun foo-a () 1))
                                    ("b.el" (defun foo-b () 2))))
               'ns-collision)))

(ert-deftest nl-ns-redefinition-in-one-file-is-not-a-collision ()
  ;; Two definitions in the SAME file are a different problem; this
  ;; pass is about cross-file ownership.
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check '(("a.el" (defun foo-a () 1)
                                     (defun foo-a () 2))))
               'ns-collision)))

;;; Prefix violations ---------------------------------------------------

(ert-deftest nl-ns-prefix-violation-is-reported ()
  (let ((findings (nl-ns-findings-of-kind
                   (nl-ns-test--check
                    '(("a.el" (defun nl-safe-one () 1)
                       (defun nl-safe-two () 2)
                       (defalias 'eql 'equal))))
                   'ns-prefix-violation)))
    (should (= (length findings) 1))
    (should (eq (plist-get (car findings) :subject) 'eql))
    (should (equal (plist-get (car findings) :expected) "nl-safe-"))))

(ert-deftest nl-ns-conforming-file-has-no-prefix-violation ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("a.el" (defun nl-safe-one () 1)
                   (defun nl-safe-two () 2))))
               'ns-prefix-violation)))

(ert-deftest nl-ns-global-file-skips-prefix-check ()
  ;; No dominant prefix means no claim, so nothing is a violation.
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("prelude.el" (defun car (x) x) (defun princ (x) x)
                   (defun terpri () nil))))
               'ns-prefix-violation)))

;;; Private escapes -----------------------------------------------------

(ert-deftest nl-ns-private-escape-is-reported ()
  (let ((findings (nl-ns-findings-of-kind
                   (nl-ns-test--check
                    '(("owner.el" (defun mine--secret () 1)
                       (defun mine-public () 2))
                      ("user.el" (defun theirs-use () (mine--secret)))))
                   'ns-private-escape)))
    (should (= (length findings) 1))
    (should (eq (plist-get (car findings) :subject) 'mine--secret))
    (should (equal (plist-get (car findings) :file) "user.el"))
    (should (equal (plist-get (car findings) :owner) "owner.el"))))

(ert-deftest nl-ns-public-reference-is-clean ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("owner.el" (defun mine-public () 2))
                  ("user.el" (defun theirs-use () (mine-public)))))
               'ns-private-escape)))

(ert-deftest nl-ns-own-private-use-is-clean ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("owner.el" (defun mine--secret () 1)
                   (defun mine-public () (mine--secret)))))
               'ns-private-escape)))

;;; Quoted namespace members ------------------------------------------

(ert-deftest nl-ns-quoted-member-is-reported-for-quote ()
  (let ((findings (nl-ns-findings-of-kind
                   (nl-ns-test--check
                    '(("text.el"
                       (nl-ns-define text :members (wrap chunk))
                       (nl-ns-in text
                         (defun wrap () 'chunk)))) )
                   'ns-quoted-member)))
    (should (= (length findings) 1))
    (should (eq (plist-get (car findings) :subject) 'chunk))
    (should (eq (plist-get (car findings) :namespace) 'text))))

(ert-deftest nl-ns-quoted-member-is-reported-for-backquote-template ()
  (dolist (heads '((\` \, \,@) (backquote comma comma-at)))
    (let* ((backquote (car heads))
           (comma (car (cdr heads)))
           (comma-at (car (cdr (cdr heads))))
           (findings
            (nl-ns-findings-of-kind
             (nl-ns-test--check
              (list
               (list "text.el"
                     (list 'nl-ns-define 'text :members '(wrap chunk))
                     (list 'nl-ns-in 'text
                           (list 'defun 'wrap nil
                                 (list backquote
                                       (list 'chunk
                                             (list comma
                                                   (list 'funcall 'wrap))
                                             (list comma-at
                                                   (list 'funcall 'wrap)))))))))
             'ns-quoted-member)))
      ;; The template's `chunk' is literal; unquoted forms are evaluated.
      (should (= (length findings) 1))
      (should (eq (plist-get (car findings) :subject) 'chunk)))))

(ert-deftest nl-ns-ambiguous-private-is-not-attributed ()
  ;; Defined in two files, so no single owner: the collision finding
  ;; covers it and attributing an escape would be a guess.
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("a.el" (defun mine--secret () 1))
                  ("b.el" (defun mine--secret () 2))
                  ("user.el" (defun u () (mine--secret)))))
               'ns-private-escape)))

;;; Undeclared dependencies ---------------------------------------------

(ert-deftest nl-ns-undeclared-dependency-is-off-by-default ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("owner.el" (provide 'owner) (defun mine-public () 1))
                  ("user.el" (defun u () (mine-public)))))
               'ns-undeclared-dependency)))

(ert-deftest nl-ns-undeclared-dependency-is-reported-when-asked ()
  (let ((findings (nl-ns-findings-of-kind
                   (nl-ns-test--check
                    '(("owner.el" (provide 'owner) (defun mine-public () 1))
                      ("user.el" (defun u () (mine-public))))
                    t)
                   'ns-undeclared-dependency)))
    (should (= (length findings) 1))
    (should (equal (plist-get (car findings) :file) "user.el"))
    (should (equal (plist-get (car findings) :subject) "owner.el"))))

(ert-deftest nl-ns-declared-dependency-is-clean ()
  (should-not (nl-ns-findings-of-kind
               (nl-ns-test--check
                '(("owner.el" (provide 'owner) (defun mine-public () 1))
                  ("user.el" (require 'owner) (defun u () (mine-public))))
                t)
               'ns-undeclared-dependency)))

;;; Unreadable files ----------------------------------------------------

(ert-deftest nl-ns-unreadable-file-is-reported ()
  (let ((findings (nl-ns-test--check '(("broken.el" . nl-ns--unreadable)))))
    (should (= (length findings) 1))
    (should (eq (plist-get (car findings) :kind) 'ns-unreadable))
    (should (equal (plist-get (car findings) :subject) "broken.el"))))

;;; Reporting ------------------------------------------------------------

(ert-deftest nl-ns-report-of-nothing ()
  (should (equal (nl-ns-report nil)
                 "nl-ns: no findings (baseline none)\n")))

(ert-deftest nl-ns-report-lists-each-finding ()
  (let ((report (nl-ns-report
                  (nl-ns-test--check
                   '(("a.el" (defun eql (a b) (eq a b)))
                     ("b.el" (defun eql (a b) (eq a b))))))))
    (should (string-match "1 finding" report))
    (should (string-match "ns-collision" report))
    (should (string-match "a.el" report))
    (should (string-match "b.el" report))))

(ert-deftest nl-ns-report-includes-baseline-and-severity-summary ()
  (let* ((baseline (nl-ns-test--baseline-file))
         (findings
          (nl-ns-test--check-files
           (list (nl-ns-test--fixture "shadow-unsafe" "cl-lib.el"))
           nil baseline))
         (report (nl-ns-report findings baseline)))
    (should (string-match "severity 1=1 2=1 3=1 6=1" report))
    (should (string-match "baseline 30.1 generated 2026-08-15" report))
    (should (string-match "ns-partial-override" report))
    (should (string-match "minimal" report))))

(ert-deftest nl-ns-report-describes-quoted-members ()
  (let ((report (nl-ns-report
                 (list (list :kind 'ns-quoted-member :subject 'chunk
                             :file "text.el" :namespace 'text)))))
    (should (string-match "ns-quoted-member" report))
    (should (string-match "chunk" report))))

(ert-deftest nl-ns-summary-counts-by-kind ()
  (let ((summary (nl-ns-summary
                   (nl-ns-test--check
                    '(("a.el" (defun eql (a b) (eq a b)))
                      ("b.el" (defun eql (a b) (eq a b)))
                     ("c.el" (defun nl-x-one () 1) (defun nl-x-two () 2)
                      (defun stray () 3)))))))
    (should (equal (cdr (assq 'ns-collision summary)) 1))
    (should (equal (cdr (assq 'ns-prefix-violation summary)) 1))))

(ert-deftest nl-ns-findings-of-kind-filters ()
  (let ((findings (nl-ns-test--check
                   '(("a.el" (defun eql (a b) (eq a b)))
                     ("b.el" (defun eql (a b) (eq a b)))))))
    (should (= (length (nl-ns-findings-of-kind findings 'ns-collision)) 1))
    (should-not (nl-ns-findings-of-kind findings 'ns-private-escape))))

(ert-deftest nl-ns-clean-tree-has-no-findings ()
  (should-not (nl-ns-test--check
               '(("a.el" (provide 'a) (defun pkg-a-one () 1)
                  (defun pkg-a-two () 2))
                 ("b.el" (require 'a) (provide 'b)
                  (defun pkg-b-one () (pkg-a-one)))))))

(provide 'nl-ns-test)

;;; nl-ns-test.el ends here
