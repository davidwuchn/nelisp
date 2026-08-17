;;; nelisp-ert-gate.el --- run ERT and report how much of it ran -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch entry point that runs ERT and writes a gate report carrying the
;; executed-case count, so that "the suite passed" and "the suite never
;; found a test" stop looking alike from the outside.  That distinction
;; is not hypothetical here: a `wildcard' in a sibling Makefile once
;; pulled non-ERT driver scripts into the test load list, the run died
;; before defining a single test, and the failure surfaced as an opaque
;; exit code rather than as "0 tests".
;;
;; Load this file after the test files, then call `nelisp-ert-gate-run'.
;;
;; Environment:
;;   NELISP_GATE_NAME      report name (default "ert")
;;   NELISP_GATE_SELECTOR  ERT selector, read as a Lisp form (default t)
;;   NELISP_GATE_COMMAND   command line recorded in the report
;;   NELISP_GATE_DIR       report directory (see `nelisp-gate-directory')

;;; Code:

(require 'ert)

(eval-and-compile
  (add-to-list 'load-path
               (file-name-directory (or load-file-name
                                        buffer-file-name
                                        default-directory))))
(require 'nelisp-gate-lib)

(defun nelisp-ert-gate--selector ()
  "Return the ERT selector from the environment, defaulting to t."
  (let ((raw (getenv "NELISP_GATE_SELECTOR")))
    (if (and raw (> (length (string-trim raw)) 0))
        (car (read-from-string raw))
      t)))

(defun nelisp-ert-gate-run ()
  "Run ERT, write a gate report, and exit with the matching code."
  (let* ((name (or (getenv "NELISP_GATE_NAME") "ert"))
         (command (or (getenv "NELISP_GATE_COMMAND") ""))
         (selector (nelisp-ert-gate--selector))
         (started (float-time))
         (stats (ert-run-tests-batch selector))
         (duration (round (* 1000 (- (float-time) started))))
         (total (ert-stats-total stats))
         (skipped (ert-stats-skipped stats))
         (passed (ert-stats-completed-expected stats))
         (failed (ert-stats-completed-unexpected stats))
         ;; Executed cases, not declared ones.  A run in which every
         ;; test was skipped is reported as ran = 0 and fails, because a
         ;; fully skipped suite that reads as green is exactly the shape
         ;; of regression this gate exists to catch.
         (ran (- total skipped))
         (reason (cond ((= total 0)
                        (format "ERT selector %S matched no test" selector))
                       ((= ran 0)
                        (format "all %d tests skipped; nothing executed" total))
                       ((> failed 0)
                        (format "%d unexpected result(s)" failed))
                       (t "")))
         (file (nelisp-gate-emit :name name
                                 :kind "ert"
                                 :ran ran
                                 :passed passed
                                 :failed failed
                                 :skipped skipped
                                 ;; REASON doubles as the skip declaration
                                 ;; in `nelisp-gate-derive-status', so the
                                 ;; verdict is computed from the counts here
                                 ;; and the prose is attached afterwards.
                                 :status (nelisp-gate-derive-status ran failed nil)
                                 :reason reason
                                 :command command
                                 :duration-ms duration)))
    (message "gate report: %s (ran %d, failed %d, skipped %d)"
             file ran failed skipped)
    (kill-emacs (nelisp-gate-exit-code
                 (nelisp-gate-derive-status ran failed nil)))))

(provide 'nelisp-ert-gate)

;;; nelisp-ert-gate.el ends here
