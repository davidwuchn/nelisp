;;; nelisp-buffer-unification-standalone-smoke.el --- Doc 188 P1 buffer smoke -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone acceptance gate for Doc 188 Phase 1 (buffer unification):
;; runs the same assertions as test/nelisp-buffer-unification-test.el's
;; `nelisp-buffer/insert-then-buffer-string-round-trips' and
;; `nelisp-buffer/goto-char-and-point-agree', plus the point-min/point-max
;; forms from Doc 188 §4.2, DIRECTLY on `target/nelisp' via the mini ERT
;; shim (`scripts/nelisp-ert-shim.el', its first real consumer).  This is
;; deliberately NOT only a host-Emacs ERT case: per Doc 188 §4.1/§1.8,
;; host Emacs already has real `insert'/`buffer-string'/`point'/`goto-
;; char', so a plain ERT run of the same forms would pass whether or not
;; this tree's own prelude wiring (scripts/nelisp-stdlib-prelude.el) is
;; correct -- it is this file's job, not the host-ERT file's, to actually
;; distinguish the fix from the bug (Doc 188 §1.3's disconnected `insert').
;;
;; Run from the repository root:
;;
;;   ./target/nelisp --load test/nelisp-buffer-unification-standalone-smoke.el
;;
;; The final line is `nelisp-buffer-unification-standalone-smoke: PASS
;; (N tests)'; any failure raises an error so the process exits non-zero.

;;; Code:

(load "scripts/nelisp-ert-shim.el")

(ert-deftest nelisp-buffer/insert-then-buffer-string-round-trips ()
  (let ((b (generate-new-buffer "smoke-t1")))
    (with-current-buffer b (insert "abc"))
    (should (equal "abc" (with-current-buffer b (buffer-string))))))

(ert-deftest nelisp-buffer/goto-char-and-point-agree ()
  (let ((b (generate-new-buffer "smoke-t2")))
    (with-current-buffer b (insert "abcdef") (goto-char 3))
    (should (= 3 (with-current-buffer b (point))))))

(ert-deftest nelisp-buffer/point-min-anchor ()
  ;; Doc 188 §4.2: `point-min' was already correct (1) before this
  ;; phase; must not regress the one thing that was already right.
  (should (= 1 (with-temp-buffer (insert "ab") (point-min)))))

(ert-deftest nelisp-buffer/point-max-was-hardcoded-one ()
  ;; Doc 188 §1.3/§4.2: `point-max' was hardcoded to 1 regardless of
  ;; buffer content; must now reflect the real buffer size + 1.
  (should (= 3 (with-temp-buffer (insert "hi") (point-max)))))

(ert-deftest nelisp-buffer/kill-buffer-then-not-live ()
  ;; Doc 188 §2.2: `kill-buffer'/`buffer-live-p'/`generate-new-buffer'
  ;; now read and write one coherent representation, not two.
  (let ((b (generate-new-buffer "smoke-t3")))
    (should (buffer-live-p b))
    (kill-buffer b)
    (should-not (buffer-live-p b))))

(ert-deftest nelisp-buffer/hello-world-round-trip ()
  ;; The task's own Definition-of-Done transcript: `insert' inside
  ;; `with-temp-file', then `insert-file-contents' into a fresh
  ;; `with-temp-buffer', all sharing the one ported buffer model.
  (let ((f (make-temp-file "nelisp-buffer-unification-smoke-")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "hello-world"))
          (should (equal "hello-world"
                          (with-temp-buffer
                            (insert-file-contents f)
                            (buffer-string)))))
      (ignore-errors (delete-file f)))))

(let* ((result (nelisp-ert-run-all "nelisp-buffer-unification"))
       (pass (nth 0 result))
       (fail (nth 1 result)))
  ;; `tools/ai/nelisp-ai.sh gate NAME -- ...' requires this exact line to
  ;; report what the gate checked; its absence is itself a hard failure
  ;; there (see tools/ai/nelisp-ai.sh's `cmd_gate').
  (princ (format "GATE-COUNT checked=%d findings=%d\n" (+ pass fail) fail))
  (if (> fail 0)
      (error "nelisp-buffer-unification-standalone-smoke: %d failure(s), %d passed"
             fail pass)
    (when (< pass 6)
      (error "nelisp-buffer-unification-standalone-smoke: only %d tests ran (expected >= 6)"
             pass))
    (princ (format "nelisp-buffer-unification-standalone-smoke: PASS (%d tests)\n" pass))))

;;; nelisp-buffer-unification-standalone-smoke.el ends here
