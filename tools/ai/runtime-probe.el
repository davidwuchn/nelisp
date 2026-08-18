;;; runtime-probe.el --- report what this standalone binary can do -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Run under the standalone runtime, not host Emacs:
;;
;;     nelisp --load tools/ai/runtime-probe.el
;;
;; Prints one PROBE line per capability, then a GATE-COUNT line.  The
;; recipes carry a hand-written table of these same facts, and a
;; hand-written table of measurements is exactly what goes stale between
;; builds: two of its entries were already wrong when this file was
;; written, and each had cost an afternoon.  The answers differ per
;; binary and per platform, so they are probed rather than remembered.
;;
;; Every probe reports what it measured, not whether it approves.  A
;; runtime that cannot do something is not failing this check; the only
;; failure would be a probe that could not run.

;;; Code:

(defvar probe-count 0)

(defmacro probe-safe (&rest body)
  "Evaluate BODY, returning (ok . VALUE) or (err . MESSAGE).

A macro rather than a function taking a thunk, because
(funcall (lambda () (float-time))) aborts this runtime without
signalling while the same call written directly is fine.  Wrapping each
probe in a lambda would have made the wrapper the thing measured."
  (list 'condition-case 'probe-error
        (list 'cons ''ok (cons 'progn body))
        (list 'error (list 'cons ''err (list 'format "%S" 'probe-error)))))

(defun probe-report (name value note)
  (setq probe-count (+ probe-count 1))
  (princ (format "PROBE %-22s %-28s %s" name value note))
  (terpri))

;;;; Environment ---------------------------------------------------------

(let* ((result (probe-safe (getenv "PATH")))
       (value (cdr result))
       (works (and (stringp value) (> (length value) 0))))
  (probe-report "getenv" (if works "works" "nil")
                (if works
                    "environment is a usable channel"
                  "pass parameters as variables in a driver file")))

;;;; Dependency resolution ----------------------------------------------

(let* ((result (probe-safe (require 'nelisp-artifact)))
       (failed (eq (car result) 'err)))
  (probe-report "require tree feature" (if failed "file-missing" "resolves")
                (if failed
                    "FEATURE is used as a literal path; no load-path search"
                  "resolves through a search path")))

(let* ((result (probe-safe (require 'no-such-feature-xyz nil t)))
       (failed (eq (car result) 'err)))
  (probe-report "require NOERROR" (if failed "signals anyway" "nil")
                "the third argument is NOERROR, not the second"))

(let* ((result (probe-safe (load "no/such/file-xyz.el" nil t)))
       (failed (eq (car result) 'err)))
  (probe-report "load missing file"
                (if failed "signals" (format "%S" (cdr result)))
                (if failed
                    "a wrong path is loud"
                  "SILENT: assert featurep after loading by path")))

;; Does a signalled error inside a loaded file stop the load?  This is
;; the probe that changes how the rest are read: if the answer is no,
;; then "it loaded fine" means nothing anywhere in this tree, including
;; in the smokes' hand-written load lists.
(ignore-errors
  (write-region
   "(require 'no-such-lib-xyz)\n(defun probe-marker-after-error () 42)\n"
   nil "target/ai/probe-error-file.el"))
(probe-report "load past an error"
              (if (progn (ignore-errors
                           (load "target/ai/probe-error-file.el" nil t))
                         (fboundp 'probe-marker-after-error))
                  "continues"
                "stops")
              "a failed require inside a file does not stop the file")

;;;; Files ---------------------------------------------------------------

(let* ((result (probe-safe (write-region "abc\n" nil "target/ai/probe-ascii.txt"))))
  (probe-report "write-region ascii"
                (if (eq (car result) 'err) "signals" "ok")
                "baseline for the next line"))

(let* ((result (probe-safe (write-region "良\n" nil "target/ai/probe-multibyte.txt")))
       (back (cdr (probe-safe
                   (with-temp-buffer
                     (insert-file-contents "target/ai/probe-multibyte.txt")
                     (buffer-string))))))
  (probe-report "write-region multibyte"
                (if (eq (car result) 'err) "signals" "ok")
                (if (equal back "良\n")
                    "the file is correct even when it signals"
                  "the file differs from what was written")))

(let* ((result (probe-safe (file-exists-p "Makefile")))
       (value (cdr result)))
  (probe-report "file-exists-p"
                (cond ((eq (car result) 'err) "signals")
                      (value "works")
                      (t "nil for a file that exists"))
                "never gate on this while it answers nil"))

;;;; Clock ---------------------------------------------------------------

(let* ((result (probe-safe (current-time)))
       (value (cdr result)))
  (probe-report "current-time" (format "%S" value)
                (if (equal value '(0 0 0 0))
                    "epoch stub: time whole processes from outside"
                  "real clock")))

;; `float-time' is deliberately not probed.  It answers nil here, but
;; getting that answer out is its own adventure: the value aborts this
;; runtime -- without signalling -- when it is let*-bound, when it goes
;; through `condition-case', and when it is passed to a user-defined
;; function, while (princ (format "%S" (float-time))) alone is fine and
;; `current-time' does all three without trouble.  Four attempts at a
;; probe measured the wrapper rather than the builtin, so the line above
;; carries the useful half of the answer and this comment carries the
;; rest.  Reported for the runtime owner; see the worklog for the date.

;;;; Paths ---------------------------------------------------------------

(let* ((ignored (probe-safe (write-region "x\n" nil "/tmp/nelisp-runtime-probe.txt")))
       (back (probe-safe
              (with-temp-buffer
                (insert-file-contents "/tmp/nelisp-runtime-probe.txt")
                (buffer-string)))))
  (probe-report "absolute posix path"
                (if (eq (car back) 'ok) "round-trips" "unreadable")
                "resolved against the current drive on Windows"))

(princ (format "GATE-COUNT checked=%d findings=0\n" probe-count))
(princ "runtime-probe: PASS\n")

;;; runtime-probe.el ends here
