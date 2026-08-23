;;; nelisp-process-adapter-test.el --- Doc 184 P1-P3 ERT -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; ERT suite for `packages/nelisp-process-adapter/src/nelisp-process-adapter.el'
;; (Doc 184 P1-P3) and `packages/nelisp-eventloop/src/nelisp-async-core.el'
;; (Doc 184 P0).
;;
;; Every case `skip-unless (fboundp 'nelisp-process-start)': the native
;; `nelisp-process-*' primitives these files build on only exist in the
;; standalone `target/nelisp' binary, not under host Emacs (Doc 184 S1.1)
;; -- exactly the same guard the existing `standalone-reader-process-smoke'
;; family of Makefile targets exists because of (AI.md: "the ERT suite
;; running under host Emacs and the built target/nelisp binary are not the
;; same claim").  This file is real coverage when run against a build of
;; this repository's own `ert' ported into the standalone runtime, or
;; against any future host-bridge that defines these primitives; today it
;; documents the exact defect shapes and their fixes, and the
;; authoritative red/green evidence is the `standalone-reader-async-core-
;; smoke' / `standalone-reader-process-adapter-smoke' /
;; `standalone-reader-process-adapter-smoke-red' / `standalone-reader-repl-
;; idle-pump-smoke' Makefile targets, run directly against the built
;; binary.

;;; Code:

(require 'ert)
;; Doc 184: DO NOT unconditionally `require' these two files here.  Both
;; unconditionally REDEFINE standard names (`accept-process-output',
;; `make-process', `run-at-time', `sit-for', `delete-process', ...) as
;; part of their whole "upgrade on load" design (Doc 184 S2) -- correct
;; for a standalone `target/nelisp' binary, but under host Emacs (which
;; is what `nelisp-ai.sh test'/`make test' run, loading every `test/*.el'
;; into ONE shared batch process) that would clobber the REAL host Emacs
;; primitives for every OTHER test file loaded afterward in the same
;; process.  Measured: loading them unconditionally here broke
;; `packages/nelisp-network/test/nelisp-network-test.el' (which calls the
;; real `accept-process-output') with `void-function alloc-bytes' from
;; deep inside this adapter's own poll loop, entirely unrelated to
;; anything nelisp-network tests on its own.  Only load when the native
;; process primitives this adapter builds on are actually present --
;; i.e. only in a context that could not possibly be plain host Emacs.
(when (fboundp 'nelisp-process-start)
  (require 'nelisp-async-core)
  (require 'nelisp-process-adapter))

(defmacro nelisp-process-adapter-test--fresh (&rest body)
  "Run BODY with a clean timer queue and process registry."
  (declare (indent 0))
  `(progn
     (nelisp-async-core-reset-timers)
     (setq nelisp-process-adapter--live nil)
     ,@body))

;; Doc 184 S5.1's own illustrative case, verbatim.
(ert-deftest nelisp-make-process-filter-not-silently-dropped ()
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let (got)
      (make-process :name "t" :command '("/bin/echo" "hi")
                    :filter (lambda (_p chunk) (push chunk got)))
      (accept-process-output nil 1)
      (should got))))

(ert-deftest nelisp-make-process-filter-arrives-incrementally ()
  "Two separate writes reach the filter as two separate chunks, not one
combined chunk read after the fact (Doc 184 S1.3's measured defect: the
prelude's own adapter could only retrieve output after a blocking wait,
never streamed)."
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let (chunks
          (p (make-process :name "cat" :command '("/bin/cat")
                            :filter (lambda (_p c) (push c chunks)))))
      (nelisp-process-write p "first-")
      (accept-process-output p 0.3)
      (nelisp-process-write p "second")
      (accept-process-output p 0.3)
      (nelisp-process-close-stdin p)
      (delete-process p)
      (should (equal (nreverse chunks) '("first-" "second"))))))

(ert-deftest nelisp-accept-process-output-does-not-drain-unrelated-processes ()
  "proc2's sentinel must not fire as a side effect of waiting on proc1
(Doc 184 S5.1's own illustrative case, and S1.3's measured defect: the
old `accept-process-output' unconditionally drained EVERY pending
process, not just the one it was asked to wait for)."
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let* (fired2
           (p1 (make-process :name "fast" :command '("/bin/sh" "-c" "exit 0")))
           (p2 (make-process :name "slow" :command '("/bin/sleep" "1")
                              :sentinel (lambda (_p m) (setq fired2 m)))))
      (accept-process-output p1 1)
      (should (null fired2))
      (should (process-live-p p2))
      (delete-process p2))))

(ert-deftest nelisp-process-adapter-sentinel-status-strings ()
  "The sentinel status-string collapse (Doc 184 S1.3: every exit reported
as the literal string \"finished\\n\" regardless of cause) is fixed:
normal exit 0 -> \"finished\\n\", nonzero exit -> \"exited abnormally
with code N\\n\", SIGTERM-killed (this substrate's `delete-process' --
native `nl_bi_process_delete_object' hardcodes SIGTERM(15), verified
against host Emacs 30.1's own `signal-process'+`process-sentinel') ->
\"terminated\\n\"."
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let (msgs)
      (let ((p (make-process :name "ok" :command '("/bin/sh" "-c" "exit 0")
                              :sentinel (lambda (_p m) (push m msgs)))))
        (accept-process-output p 1) (accept-process-output p 1))
      (let ((p (make-process :name "bad" :command '("/bin/sh" "-c" "exit 7")
                              :sentinel (lambda (_p m) (push m msgs)))))
        (accept-process-output p 1) (accept-process-output p 1))
      (let ((p (make-process :name "sl" :command '("/bin/sleep" "1")
                              :sentinel (lambda (_p m) (push m msgs)))))
        (accept-process-output p 0.2)
        (delete-process p))
      (should (equal (nreverse msgs)
                      '("finished\n" "exited abnormally with code 7\n" "terminated\n"))))))

(ert-deftest nelisp-accept-process-output-return-value ()
  "Non-nil iff real output was received before the timeout -- measured
against host Emacs 30.1: a timeout with nothing ready, or a process that
merely changed status with no output, both return nil; actual bytes
return t."
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let ((p (make-process :name "slow" :command '("/bin/sleep" "2"))))
      (should (null (accept-process-output p 0.1)))
      (delete-process p))
    (let (got (p (make-process :name "echo" :command '("/bin/echo" "hi")
                                :filter (lambda (_p c) (setq got c)))))
      (should (accept-process-output p 1))
      (should (equal got "hi\n")))))

(ert-deftest nelisp-process-adapter-run-at-time-repeat-through-shared-loop ()
  "`run-at-time' REPEAT fires through the SAME poll loop
`accept-process-output' uses (Doc 184 S2's decided direction), not a
separate mechanism -- closing `tools/partial-accepted.txt''s `run-at-time'
entry for anything that loads this adapter."
  (skip-unless (fboundp 'nelisp-process-start))
  (nelisp-process-adapter-test--fresh
    (let ((n 0))
      (run-at-time 0 0.02 (lambda () (setq n (1+ n))))
      (accept-process-output nil 0.3)
      (should (>= n 2)))))

(ert-deftest nelisp-make-network-process-signals-clear-error-not-silent ()
  "Doc 184 S1.7/P4: `make-network-process' is out of scope (no native
socket primitive family exists), but it must signal a clear, named error
-- not stay void-function, and not silently no-op or return a broken
process object."
  (skip-unless (fboundp 'nelisp-process-start))
  (should-error (make-network-process :name "x") :type 'error))

;; Doc 184 P0's own exit criterion, verbatim (REPEAT re-arms and fires
;; more than once across two `--fire-due' calls with an intervening
;; sleep) -- this one only needs `nelisp-async-core', not the process
;; primitives, so it is gated on `alloc-bytes' (the nanosleep builtin)
;; like the rest of this package's timer tests.
(ert-deftest nelisp-async-core-repeat-fires-more-than-once ()
  (skip-unless (fboundp 'alloc-bytes))
  (nelisp-process-adapter-test--fresh
    (let ((n 0))
      (nelisp-async-core-run-at-time 0 0.01 (lambda () (setq n (1+ n))))
      (nelisp-async-core--fire-due (+ (nelisp-async-core--now) 0.001))
      (nelisp-async-core--nanosleep 0.02)
      (nelisp-async-core--fire-due (nelisp-async-core--now))
      (should (> n 1)))))

(provide 'nelisp-process-adapter-test)
;;; nelisp-process-adapter-test.el ends here
