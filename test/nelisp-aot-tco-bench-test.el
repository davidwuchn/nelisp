;;; nelisp-aot-tco-bench-test.el --- Doc 171 benchmark proof -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Gated proof for Doc 171 G4: on the supported native-exec proof lane,
;; the transparent TCO-rewritten self-tail-recursive `defun' must run
;; at least as fast as the handwritten `nl-loop' form of the same sum
;; algorithm, within the documented 0.95x floor.

;;; Code:

(require 'ert)
(require 'nelisp-aot-tco-bench)

(ert-deftest nelisp-aot-tco-bench-tco-keeps-up-with-nl-loop ()
  "Doc 171 G4 performance proof."
  (skip-unless (nelisp-aot-tco-bench-supported-p))
  (let ((result (nelisp-aot-tco-bench-run)))
    (should (= (plist-get result :tco-value)
               (plist-get result :expected)))
    (should (= (plist-get result :loop-value)
               (plist-get result :expected)))
    (message "DOC171 BENCH tco=%.4fs loop=%.4fs ratio=%.3fx threshold=%.2f"
             (plist-get result :tco-seconds)
             (plist-get result :loop-seconds)
             (plist-get result :ratio)
             (plist-get result :threshold))
    (should (plist-get result :pass))))

(provide 'nelisp-aot-tco-bench-test)

;;; nelisp-aot-tco-bench-test.el ends here
