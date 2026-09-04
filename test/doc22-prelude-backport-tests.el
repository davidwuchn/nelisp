(require 'cl-lib)
(require 'ert)

(ert-deftest nelisp-doc22-cl-dolist-dotimes-establish-anonymous-block ()
  "The guarded prelude shims retain GNU's anonymous `cl-block'."
  (let ((old-dolist (symbol-function 'cl-dolist))
        (old-dotimes (symbol-function 'cl-dotimes))
        dolist-form
        dotimes-form)
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "scripts/nelisp-stdlib-prelude.el"
                         default-directory))
      (goto-char (point-min))
      (search-forward "(unless (fboundp 'cl-dolist)")
      (beginning-of-line)
      (setq dolist-form (read (current-buffer)))
      (search-forward "(unless (fboundp 'cl-dotimes)")
      (beginning-of-line)
      (setq dotimes-form (read (current-buffer))))
    (unwind-protect
        (progn
          (fmakunbound 'cl-dolist)
          (fmakunbound 'cl-dotimes)
          (eval dolist-form t)
          (eval dotimes-form t)
          (should
           (equal (macroexpand-1
                   '(cl-dolist (x '(1 2) 'done) (cl-return x)))
                  '(cl-block nil
                     (dolist (x '(1 2) 'done) (cl-return x)))))
          (should
           (equal (macroexpand-1
                   '(cl-dotimes (i 3 'done) (cl-return i)))
                  '(cl-block nil
                     (dotimes (i 3 'done) (cl-return i)))))
          (should
           (equal (eval
                   '(list
                     (cl-dolist (x '(1 2 3) 'miss)
                       (when (= x 2) (cl-return x)))
                     (cl-dolist (x '(1 2) 'done))
                     (cl-dotimes (i 3 'miss)
                       (when (= i 2) (cl-return i)))
                     (cl-dotimes (i 3))
                     (let ((seen nil))
                       (cl-dolist (x '(1 2))
                         (push (cl-dolist (y '(3 4) 'miss)
                                 (cl-return (list x y)))
                               seen))
                       (nreverse seen)))
                   t)
                  '(2 done 2 nil ((1 3) (2 3))))))
      (fset 'cl-dolist old-dolist)
      (fset 'cl-dotimes old-dotimes))))

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
