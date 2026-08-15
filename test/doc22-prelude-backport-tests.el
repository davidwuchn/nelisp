(require 'ert)

(ert-deftest nelisp-doc22-copy-sequence-copies-string-and-vector ()
  (let ((s "abc")
        (v [1 2 3]))
    (let ((s-copy (copy-sequence s))
          (v-copy (copy-sequence v)))
      (aset s-copy 0 ?x)
      (aset v-copy 0 9)
      (should (equal s "abc"))
      (should (equal s-copy "xbc"))
      (should (equal v [1 2 3]))
      (should (equal v-copy [9 2 3])))))

(ert-deftest nelisp-doc22-mapcar-iterates-arrays ()
  (should (equal (mapcar #'identity [1 2 3]) '(1 2 3)))
  (should (equal (mapcar #'identity "ab") '(97 98))))

(ert-deftest nelisp-doc22-mapc-iterates-arrays ()
  (let ((seen nil)
        (vec [1 2 3]))
    (should (eq (mapc (lambda (x) (setq seen (cons x seen))) vec) vec))
    (should (equal (nreverse seen) '(1 2 3)))))

(ert-deftest nelisp-doc22-princ-honors-function-stream ()
  (let ((out ""))
    (should (equal (princ "xy"
                          (lambda (ch)
                            (setq out (concat out (char-to-string ch)))))
                   "xy"))
    (should (equal out "xy"))))

(ert-deftest nelisp-doc22-equal-does-not-eq-shortcut-strings ()
  ;; Build the vectors with `vector': a vector literal is
  ;; self-evaluating, so `[(concat "a" "b")]' holds the list
  ;; (concat "a" "b") rather than the string it would produce, and the
  ;; comparison never reaches the string path this test is about.
  (should (equal (vector "ab") (vector (concat "a" "b"))))
  (should-not (equal (vector "ab") (vector "ac"))))

(ert-deftest nelisp-doc22-substring-slices-vectors ()
  (should (equal (substring [1 2 3 4] 1 3) [2 3]))
  (should (equal (substring [1 2 3 4] -3 -1) [2 3])))

(ert-deftest nelisp-doc22-format-applies-precision-to-percent-S ()
  (should (equal (format "%.3S" "abcdef") "\"ab"))
  (should (equal (format "%6.3S" "abcdef") "   \"ab")))

(ert-deftest nelisp-doc22-prin1-honors-function-stream ()
  (let ((out ""))
    (should (equal (prin1 "xy"
                          (lambda (ch)
                            (setq out (concat out (char-to-string ch)))))
                   "xy"))
    (should (equal out "\"xy\""))))

(ert-deftest nelisp-doc22-terpri-honors-function-stream ()
  (let ((out ""))
    (should (eq (terpri (lambda (ch)
                          (setq out (concat out (char-to-string ch)))))
                t))
    (should (equal out "\n"))))
