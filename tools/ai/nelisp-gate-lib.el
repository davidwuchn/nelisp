;;; nelisp-gate-lib.el --- machine-checkable gate reports -*- lexical-binding: t; -*-

;;; Commentary:

;; A gate has three outcomes, not two: it can pass, it can fail, and it
;; can fail to run at all.  The third outcome is why this file exists.
;; Both of the following have shipped as "green" in this repository:
;;
;;   - a CI gate placed after an already-red target, so the job stopped
;;     before reaching it and the gate never executed once;
;;   - a test glob that matched no ERT file, so the suite reported
;;     success while running zero cases.
;;
;; Neither is visible in an exit code, so gates report counts instead of
;; relying on one.  Every gate writes a JSON report into
;; `nelisp-gate-directory', and the aggregator derives the verdict from
;; those reports plus the expected-gate manifest.  A gate that produced
;; no report at all is therefore itself a reportable failure.
;;
;; The JSON is written by hand rather than through json.el.  This file is
;; loaded by batch jobs whose entire purpose is to be trustworthy, and
;; json.el's nil/false/empty-object ambiguities are a poor foundation for
;; that.  Only strings and integers are emitted, so no ambiguity arises.

;;; Code:

(require 'cl-lib)

(defconst nelisp-gate-schema "nelisp-gate/1"
  "Schema tag written into every gate report.")

(defun nelisp-gate-directory ()
  "Return the directory gate reports are written into.
The environment variable `NELISP_GATE_DIR' overrides the default of
`target/gates' below `default-directory'."
  (file-name-as-directory
   (or (getenv "NELISP_GATE_DIR")
       (expand-file-name "target/gates"))))

(defun nelisp-gate--json-escape (string)
  "Return STRING as a quoted JSON string literal."
  (let ((out "\""))
    (dolist (ch (append string nil))
      (setq out
            (concat out
                    (cond ((eq ch ?\") "\\\"")
                          ((eq ch ?\\) "\\\\")
                          ((eq ch ?\n) "\\n")
                          ((eq ch ?\r) "\\r")
                          ((eq ch ?\t) "\\t")
                          ((< ch 32) (format "\\u%04x" ch))
                          (t (char-to-string ch))))))
    (concat out "\"")))

(defun nelisp-gate--json-value (value)
  "Render VALUE as JSON.  Only strings and integers are supported."
  (cond ((integerp value) (number-to-string value))
        ((stringp value) (nelisp-gate--json-escape value))
        ((null value) (nelisp-gate--json-escape ""))
        (t (nelisp-gate--json-escape (format "%s" value)))))

(defun nelisp-gate-derive-status (ran failed skip-reason)
  "Return the gate status string for RAN, FAILED and SKIP-REASON.

A gate is green only when it executed at least one case and none of
them failed.  RAN = 0 is a failure, not a pass: it means the gate was
wired up but never exercised anything, which is the condition this
whole mechanism exists to surface.

A gate may declare itself skipped by passing a non-empty SKIP-REASON —
for example a Linux-only smoke invoked on Windows.  The reason is
mandatory, because a skip without one is indistinguishable from a gate
that quietly stopped working.

A reason does not mask failures.  The first version of this function
tested SKIP-REASON before FAILED, so any gate that explained itself
while failing reported `skip'; `gate-report.sh' had the guard and this
did not, which is precisely the sort of divergence that makes two
implementations of one rule worth testing."
  (cond ((and (stringp skip-reason) (> (length skip-reason) 0)
              (= failed 0))
         "skip")
        ((> failed 0) "fail")
        ((= ran 0) "fail")
        (t "pass")))

(defun nelisp-gate-exit-code (status)
  "Return the process exit code matching gate STATUS."
  (if (member status '("pass" "skip")) 0 1))

(cl-defun nelisp-gate-emit (&key name (kind "custom") (ran 0) (passed 0)
                                 (failed 0) (skipped 0) (reason "")
                                 (command "") (duration-ms 0) status)
  "Write one gate report and return its file name.

NAME is the report's identity and its file name stem; it must match the
entry in `tools/ai/gates.expected' for gates the aggregator requires.
KIND is a free-form category (\"ert\", \"smoke\", \"bench\", ...).

RAN is the number of cases actually executed, which is the field that
makes a silent no-op detectable — pass a real count, never a constant.
REASON is required when STATUS is \"skip\" and is otherwise free text
explaining a failure.  STATUS overrides the derived verdict; leave it
nil unless the gate genuinely knows better than the counts."
  (unless (and (stringp name) (> (length name) 0))
    (error "nelisp-gate-emit: NAME is required"))
  (let* ((status (or status (nelisp-gate-derive-status ran failed reason)))
         (dir (nelisp-gate-directory))
         (file (expand-file-name (concat name ".json") dir))
         (fields
          (list (cons "schema" nelisp-gate-schema)
                (cons "name" name)
                (cons "kind" kind)
                (cons "status" status)
                (cons "ran" ran)
                (cons "passed" passed)
                (cons "failed" failed)
                (cons "skipped" skipped)
                (cons "reason" (or reason ""))
                (cons "command" (or command ""))
                (cons "duration_ms" duration-ms)
                (cons "finished" (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                (cons "host" (system-name)))))
    (make-directory dir t)
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file file
        (insert "{\n")
        (insert (mapconcat (lambda (pair)
                             (format "  %s: %s"
                                     (nelisp-gate--json-escape (car pair))
                                     (nelisp-gate--json-value (cdr pair))))
                           fields
                           ",\n"))
        (insert "\n}\n")))
    file))

(provide 'nelisp-gate-lib)

;;; nelisp-gate-lib.el ends here
