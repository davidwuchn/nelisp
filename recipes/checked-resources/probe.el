;;; probe.el --- exercise and measure the checked-resources skeleton -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the repository root:
;;
;;   nelisp --load recipes/checked-resources/probe.el              # behaviour
;;   PROBE_ARM=checked PROBE_ITERATIONS=4000 nelisp --load ...     # one timed arm
;;
;; The timing is done by the caller, not here, because the standalone
;; runtime has no usable clock: `(current-time)' answers `(0 0 0 0)' and
;; `(float-time)' answers nil.  So each timed arm is a whole process,
;; and `verify.sh' times it from outside and subtracts an empty run of
;; the same arm to remove start-up — the slope method this repository
;; already uses for its own benchmarks.
;;
;; PROBE_ARM selects what to do:
;;
;;   behaviour (default)  correctness + the borrow-violation corpus
;;   plain                PROBE_ITERATIONS unchecked sums, nothing else
;;   checked              PROBE_ITERATIONS borrow-checked sums

;;; Code:

(load "packages/nl-prelude/src/nl-prelude.el" nil t)
(load "packages/nl-safe/src/nl-safe.el" nil t)
(load "packages/nl-safe/src/nl-safe-report.el" nil t)
(load "recipes/checked-resources/skeleton/checked.el" nil t)

(defun probe-iterations ()
  "Return the iteration count requested through the environment."
  (let ((raw (getenv "PROBE_ITERATIONS")))
    (if (and raw (> (length raw) 0))
        (string-to-number raw)
      0)))

(defun probe-report (key value)
  (princ (format "RESULT %s=%s" key value))
  (terpri))

(defun probe-repeat (n fn)
  "Call FN N times and return the last value.
The value is returned, and printed by the caller, so that a loop which
did not run cannot look like one that did."
  (let ((i 0)
        (last nil))
    (while (< i n)
      (setq last (funcall fn))
      (setq i (+ i 1)))
    last))

(defun probe-behaviour ()
  "Check that the borrow discipline does what it claims."
  (checked-fill 3)
  (probe-report "sum" (checked-sum))
  ;; The important one: a recipe that only exercises the legal path
  ;; proves the code runs, not that the checker works.
  (probe-report "conflict" (checked-conflict))
  ;; Violation logging is the data source Doc 168's Phase 6 gate reads,
  ;; so running this smoke contributes to that corpus.
  (setq nl-safe-log-violations t)
  (checked-conflict)
  (let ((log "target/ai/nl-safe-violations.log"))
    (ignore-errors (nl-safe-report-dump log t))
    (let ((summary (ignore-errors (nl-safe-report-summarize-file log))))
      (probe-report "violations" (or (plist-get summary :total) 0))))
  (setq nl-safe-log-violations nil))

(defun probe-run ()
  (let ((arm (or (getenv "PROBE_ARM") "behaviour")))
    (cond
     ((equal arm "plain")
      (checked-fill 3)
      (probe-report "arm" "plain")
      (probe-report "last" (probe-repeat (probe-iterations)
                                         #'checked-plain-sum)))
     ((equal arm "checked")
      (checked-fill 3)
      (probe-report "arm" "checked")
      (probe-report "last" (probe-repeat (probe-iterations)
                                         #'checked-sum)))
     (t
      (probe-behaviour))))
  'probe-done)

(probe-run)

;;; probe.el ends here
