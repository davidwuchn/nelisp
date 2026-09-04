;;; nelisp-float-time-arg-test.el --- (float-time TIME) honours TIME -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `float-time' in the standalone reader was a ZERO-ARGUMENT hand-assembled
;; builtin -- `((:lit "float-time") . (wf_float_time out))' in
;; scripts/nelisp-standalone-build.el, which reads the wall clock and never
;; looks at `args'.  It therefore ignored its TIME argument and answered the
;; current time for every call.  Measured on v1.2.0 (a9ad34d7b), linux-x86_64,
;; target/nelisp sha=9b3439d619fee537 size=8295776:
;;
;;   (float-time 5)          => 1788496822.469472    Emacs: 5.0
;;   (float-time 0.25)       => 1788496822.598245    Emacs: 0.25
;;   (float-time '(0 5 0 0)) => 1788496822.727717    Emacs: 5.0
;;   (float-time)            => 1788496822.857055    correct
;;
;; so every `(float-time (time-subtract (current-time) start))' -- the
;; standard elapsed-seconds idiom -- reported ~1.79e9 seconds of "elapsed"
;; time.  Nothing signalled; the caller got a plausible number.
;;
;; Host Emacs has a correct `float-time' of its own, so a host-only ERT case
;; would be green with and without the fix -- the blind spot
;; test/nelisp-buffer-unification-standalone-smoke.el's Commentary describes,
;; and the one `float-time' fell into.  Every assertion below therefore runs
;; `target/nelisp' itself, the way test/nelisp-doc200-unibyte-repr-test.el
;; does, and skips with a reason when that binary has not been built.
;;
;; The expected strings are not invented.  Each was read off a real GNU Emacs
;; batch run before it was written here, and `nelisp-float-time/host-emacs-
;; pins-the-oracle' below re-derives the same values from the host's own
;; `float-time' on every run, so a wrong expectation cannot sit here quietly.
;; The same forms are also in test/nelisp-shadow-differential-cases.el, where
;; `emacs-parity' diffs them against a live Emacs.

;;; Code:

(require 'ert)
(require 'subr-x)

(defconst nelisp-float-time-arg-test--repo-root
  (file-name-as-directory
   (expand-file-name ".." (file-name-directory
                           (or load-file-name buffer-file-name))))
  "Absolute root of the checkout holding this test.")

(defconst nelisp-float-time-arg-test--cases
  '(("(float-time 5)"                     . "5.0")
    ("(float-time 0)"                     . "0.0")
    ("(float-time -1)"                    . "-1.0")
    ("(float-time 0.25)"                  . "0.25")
    ("(float-time '(0 5 0 0))"            . "5.0")
    ("(float-time '(0 5))"                . "5.0")
    ("(float-time '(1 0))"                . "65536.0")
    ("(float-time '(0 -5))"               . "-5.0")
    ("(float-time '(0 5 500000))"         . "5.5")
    ("(float-time '(0 5 -500000))"        . "4.5")
    ("(float-time '(0 0 0 500000000000))" . "0.5")
    ("(float-time '(1 2 3 4))"            . "65538.00000300001")
    ("(float-time '(1 2 3 4 5))"          . "65538.00000300001")
    ("(float-time '(1 2 3 . 4))"          . "65538.000003")
    ("(float-time '(27278 123 456789 987654))" . "1787691131.45679")
    ("(float-time '(1 . 4))"              . "0.25")
    ("(float-time '(3 . 1))"              . "3.0")
    ("(float-time '(1 . 1000000000000))"  . "1e-12"))
  "Expressions and the exact printed value GNU Emacs answers for each.")

(defconst nelisp-float-time-arg-test--invalid
  '("(float-time \"x\")"
    "(float-time t)"
    "(float-time [1 2])"
    "(float-time '(1))"
    "(float-time '(1 . -4))"
    "(float-time '(1 . 0))"
    "(float-time '(1 . 2.0))"
    "(float-time '(0 5.0))")
  "TIME arguments GNU Emacs rejects with `Invalid time specification'.")

(defun nelisp-float-time-arg-test--binary ()
  "Return the standalone binary path, or skip the test when it is absent."
  (let ((binary (expand-file-name "target/nelisp"
                                  nelisp-float-time-arg-test--repo-root)))
    (unless (file-executable-p binary)
      (ert-skip "target/nelisp is not built; standalone-reader-test owns it"))
    binary))

(defun nelisp-float-time-arg-test--eval (expression)
  "Return `target/nelisp''s trimmed stdout for EXPRESSION."
  (let ((binary (nelisp-float-time-arg-test--binary)))
    (with-temp-buffer
      (let ((rc (call-process binary nil t nil "--eval" expression)))
        (unless (= rc 0)
          (ert-fail (format "standalone %s failed: rc=%S out=%S"
                            expression rc (buffer-string))))
        (string-trim (buffer-string))))))

(ert-deftest nelisp-float-time/standalone-honours-time-argument ()
  "Every documented TIME shape converts, instead of answering the clock.

Red before the fix: each of these returned the wall clock (~1.79e9),
never the expected value."
  (dolist (case nelisp-float-time-arg-test--cases)
    (should (equal (cdr case)
                   (nelisp-float-time-arg-test--eval (car case))))))

(ert-deftest nelisp-float-time/standalone-rejects-invalid-specification ()
  "A TIME Emacs cannot decode signals rather than inventing a number.

Red before the fix: each of these returned the wall clock."
  (dolist (expression nelisp-float-time-arg-test--invalid)
    (should (equal "(error \"Invalid time specification\")"
                   (nelisp-float-time-arg-test--eval
                    (format "(condition-case e %s (error e))" expression))))))

(ert-deftest nelisp-float-time/standalone-no-argument-still-reads-the-clock ()
  "The zero-argument path is the one thing that already worked.

`(float-time)' and `(float-time nil)' must both still answer the wall
clock, within a second of the host's own reading -- the fix must not
have moved the clock path onto the conversion path."
  (let ((host (float-time)))
    (dolist (expression '("(float-time)" "(float-time nil)"))
      (let ((got (string-to-number
                  (nelisp-float-time-arg-test--eval expression))))
        (should (> got 1.7e9))
        (should (< (abs (- got host)) 60.0))))))

(ert-deftest nelisp-float-time/standalone-elapsed-seconds-idiom ()
  "The idiom the defect actually broke: a small interval reads small.

Before the fix this answered ~1.79e9 for a fraction of a second."
  (let ((got (string-to-number
              (nelisp-float-time-arg-test--eval
               "(float-time '(0 0 250000 0))"))))
    (should (< (abs (- got 0.25)) 1e-9))))

(ert-deftest nelisp-float-time/host-emacs-pins-the-oracle ()
  "Re-derive every expected value from the host's own `float-time'.

This case asserts nothing about NeLisp.  It exists so that a wrong
expectation in `nelisp-float-time-arg-test--cases' fails here, in the
oracle, rather than being blamed on the standalone."
  (dolist (case nelisp-float-time-arg-test--cases)
    (let ((form (car (read-from-string (car case)))))
      (should (equal (cdr case) (format "%S" (eval form t))))))
  (dolist (expression nelisp-float-time-arg-test--invalid)
    (let ((form (car (read-from-string expression))))
      (should (equal '(error "Invalid time specification")
                     (condition-case e (progn (eval form t) nil)
                       (error e)))))))

(provide 'nelisp-float-time-arg-test)
;;; nelisp-float-time-arg-test.el ends here
