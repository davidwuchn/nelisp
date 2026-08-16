;;; nl-violation-corpus.el --- collect a Phase 6 gate corpus -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 168 Phase 6 / Doc 170 Stage 5 gate: static linearity checking is
;; only worth building if more than half the violations the dynamic
;; checks actually catch are statically decidable.  That decision needs
;; a corpus of real violation records, and `nl-safe--violation-log'
;; stays empty until something exercises the checks.
;;
;; Nothing in the tree uses nl-cell / fat pointers / contracts in anger
;; yet, so the honest first sample is OUR OWN TEST SUITE: the nl-safe,
;; nl-resource and nl-contract ERT files drive every violation path on
;; purpose.  That is a biased sample -- tests provoke violations that
;; production code would mostly avoid, and they provoke each kind about
;; equally -- and the printed report says so.  Treat it as a pipeline
;; check and a lower bound on record shape, not as evidence about real
;; usage.
;;
;; Run from the repository root:
;;   make nl-violation-corpus
;;
;; Appends to .nl-violations/corpus.log (git-ignored) and prints the
;; `nl-safe-report-summarize' tally.

;;; Code:

(require 'ert)
(require 'nl-safe)
(require 'nl-safe-report)

(defconst nl-violation-corpus--dir ".nl-violations")
(defconst nl-violation-corpus--file ".nl-violations/corpus.log")

(defconst nl-violation-corpus--suites
  '("nl-safe-test" "nl-resource-test" "nl-contract-test"
    ;; The one suite that drives a REAL module boundary rather than a
    ;; synthetic fixture (Doc 170 section 7.2): contracts on the
    ;; nelisp-json public API.  Records from here are the only part of
    ;; the corpus that reflects adoption instead of test scaffolding.
    "nl-contract-nelisp-json-test")
  "ERT files whose bodies exercise the dynamic checks.")

(defun nl-violation-corpus-run ()
  "Run the violation-driving suites with logging on and report."
  (make-directory nl-violation-corpus--dir t)
  (setq nl-safe-log-violations t)
  (nl-safe-report-clear)
  (dolist (suite nl-violation-corpus--suites)
    (condition-case err
        (require (intern suite))
      (error (princ (format "nl-violation-corpus: cannot load %s: %S\n"
                            suite err)))))
  ;; `ert-run-tests-batch' prints its own summary; the violations we
  ;; want are the ones the test bodies trigger on the way through.
  (let ((ert-quiet t))
    (ert-run-tests-batch t))
  (let ((count (length nl-safe--violation-log)))
    (nl-safe-report-dump nl-violation-corpus--file t)
    (let* ((summary (nl-safe-report-summarize-file nl-violation-corpus--file))
           (static (plist-get summary :static))
           (yes (plist-get static :yes))
           (no (plist-get static :no))
           (unknown (plist-get static :unknown))
           (total (plist-get summary :total))
           (classified (+ yes no)))
      (princ (format "\nnl-violation-corpus: %d new record(s) this run; %d in %s\n"
                     count total nl-violation-corpus--file))
      (princ (format "  by kind: %S\n" (plist-get summary :by-kind)))
      (princ (format "  statically decidable: yes=%d no=%d unclassified=%d\n"
                     yes no unknown))
      (if (zerop classified)
          (princ "  gate: NOT EVALUABLE -- every record is unclassified.
  The :static field is filled in by a human reading the record; the
  Doc 168 Phase 6 gate (>50%) cannot be computed until some are.\n")
        (princ (format "  gate: %.1f%% of classified records are statically decidable (threshold 50%%)\n"
                       (/ (* 100.0 yes) classified))))
      (princ "  NOTE: most of this corpus comes from test suites, which provoke
  violations deliberately.  Only the nelisp-json contract records come
  from a real module boundary; the rest validates the pipeline and the
  record shape rather than sampling usage.\n"))))

(nl-violation-corpus-run)

;;; nl-violation-corpus.el ends here
