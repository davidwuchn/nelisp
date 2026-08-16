;;; nl-safe-collect.el --- gather the violation data Stage 5 is gated on  -*- lexical-binding: t; -*-

;;; Commentary:

;; Doc 170 section 8 puts a gate in front of Stage 5 (static linearity
;; checking):
;;
;;   more than 50% of the violations `nl-safe--violation-log' captured
;;   must be statically decidable; below that, abandon the Stage and
;;   spend the effort on the dynamic checks instead.
;;
;; and says in as many words not to defer that decision.  The machinery
;; to answer it already exists -- `nl-safe-report-dump' writes the log,
;; `nl-safe-report-summarize' counts the `:static' field -- but nothing
;; ever ran with logging on, so the log has always been empty and the
;; gate has never been answerable.  This runs the safety suites with
;; logging enabled and writes the dump.
;;
;; The `:static' field lands as `unknown'.  Classifying each record as
;; `yes' or `no' is a reading task, not something this script should
;; guess: the gate is the whole reason the Stage exists or does not, and
;; a classifier that flatters the answer would decide it by accident.
;;
;; Usage:
;;   emacs -Q --batch -L packages/nl-prelude/src -L packages/nl-safe/src \
;;     -L packages/nl-safe/test -l scripts/nl-safe-collect.el

;;; Code:

(require 'ert)
(require 'nl-safe)
(require 'nl-resource)
(require 'nl-safe-report)

(defvar nl-safe-collect-output "build/nl-safe-violations.el"
  "Where the dump lands.")

(defvar nl-safe-collect-suites
  '("nl-safe-test" "nl-resource-test")
  "Test files run to exercise the dynamic checks.")

(setq nl-safe-log-violations t)
(setq nl-safe--violation-log nil)

(dolist (suite nl-safe-collect-suites)
  (condition-case err
      (load suite)
    (error (princ (format "could not load %s: %S\n" suite err)))))

;; Run every registered test.  Failures are expected and irrelevant here:
;; what is wanted is the violations the bodies provoke on the way.
(let ((ert-batch-backtrace-right-margin 0))
  (ignore-errors (ert-run-tests-batch t)))

(let ((count (length nl-safe--violation-log)))
  (make-directory (file-name-directory nl-safe-collect-output) t)
  (nl-safe-report-dump nl-safe-collect-output)
  (princ (format "captured %d violation record(s) -> %s\n"
                 count nl-safe-collect-output))
  (let* ((records (nl-safe-report-load nl-safe-collect-output))
         (summary (nl-safe-report-summarize records))
         (static (plist-get summary :static)))
    (princ (format "total=%d by-kind=%S\n"
                   (plist-get summary :total)
                   (plist-get summary :by-kind)))
    (princ (format "static: yes=%d no=%d unknown=%d\n"
                   (plist-get static :yes)
                   (plist-get static :no)
                   (plist-get static :unknown)))
    (princ "\nThe gate needs yes/(yes+no) > 50%.  Every record is\n")
    (princ "`unknown' until somebody reads it; classify in the dump.\n")))

;;; nl-safe-collect.el ends here
