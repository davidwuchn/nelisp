;;; nelisp-buffer-unification-test.el --- Doc 188 P1 against-the-bug ERT -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs ERT companion to
;; `test/nelisp-buffer-unification-standalone-smoke.el', per Doc 188
;; §4.1's exact test bodies (P1 subset only -- the third test in that
;; section, `nelisp-buffer/marker-shifts-on-earlier-insert', needs
;; `point-marker'/`set-marker' wired to standard names, which is Doc 188
;; P4, not this phase).
;;
;; IMPORTANT (Doc 188 §1.8/§4.1): under host Emacs these forms call
;; Emacs's OWN real `generate-new-buffer'/`insert'/`buffer-string'/
;; `point'/`goto-char' -- `scripts/nelisp-stdlib-prelude.el' is never
;; loaded by `make test' at all.  This file passing says nothing about
;; whether this tree's own prelude wiring is correct; that is exactly
;; what `test/nelisp-buffer-unification-standalone-smoke.el' (run
;; against `target/nelisp' itself) exists to prove.  Keep both: this
;; file is the readable spec Doc 188 §4.1 asks for and a regression
;; check against host-Emacs semantics drifting; the standalone smoke is
;; the one that can actually fail on this tree's own defect.

;;; Code:

(require 'ert)

(ert-deftest nelisp-buffer/insert-then-buffer-string-round-trips ()
  (let ((b (generate-new-buffer "t")))
    (with-current-buffer b (insert "abc"))
    (should (equal "abc" (with-current-buffer b (buffer-string))))))

(ert-deftest nelisp-buffer/goto-char-and-point-agree ()
  (let ((b (generate-new-buffer "t")))
    (with-current-buffer b (insert "abcdef") (goto-char 3))
    (should (= 3 (with-current-buffer b (point))))))

;;; nelisp-buffer-unification-test.el ends here
