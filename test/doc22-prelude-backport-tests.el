(require 'cl-lib)
(require 'ert)

(defun nelisp-doc22--prelude-defun-form (name)
  "Read the definition of NAME from the standalone prelude."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "scripts/nelisp-stdlib-prelude.el" default-directory))
    (goto-char (point-min))
    (re-search-forward
     (concat "^(defun " (regexp-quote (symbol-name name)) "\\_>"))
    (beginning-of-line)
    (read (current-buffer))))

(ert-deftest nelisp-doc22-read-from-string-decodes-gnu-string-escapes ()
  "The prelude string decoder matches GNU's escape values and byte shape."
  (let* ((names '(nelisp--rd-hex-digit-value
                  nelisp--rd-octal-escape
                  nelisp--rd-unicode-escape
                  nelisp--rd-named-unicode-escape
                  nelisp--rd-string-ctrl-char
                  nelisp--rd-basic-string-escape
                  nelisp--rd-modified-string-escape
                  nelisp--rd-string-escape
                  nelisp--rd-unescape))
         (old (mapcar (lambda (name)
                        (list name (fboundp name)
                              (and (fboundp name) (symbol-function name))))
                      names)))
    (unwind-protect
        (progn
          (dolist (name names)
            (eval (nelisp-doc22--prelude-defun-form name) t))
          (should
           (equal
            (mapcar
             #'string-to-list
             (list (nelisp--rd-unescape "x\\0y")
                   (nelisp--rd-unescape "\\012")
                   (nelisp--rd-unescape "\\101")
                   (nelisp--rd-unescape "\\x41")
                   (nelisp--rd-unescape "\\x41\\ ")
                   (nelisp--rd-unescape "é")
                   (nelisp--rd-unescape "\\u00e9")
                   (nelisp--rd-unescape "\\U0001F600")
                   (nelisp--rd-unescape "\\N{U+1F600}")
                   (nelisp--rd-unescape "\\C-a")
                   (nelisp--rd-unescape "\\^a")
                   (nelisp--rd-unescape "\\s")
                   (nelisp--rd-unescape "\\d")
                   (nelisp--rd-unescape "\\e")
                   (nelisp--rd-unescape "\\a")
                   (nelisp--rd-unescape "\\b")
                   (nelisp--rd-unescape "\\f")
                   (nelisp--rd-unescape "\\n")
                   (nelisp--rd-unescape "\\r")
                   (nelisp--rd-unescape "\\t")
                   (nelisp--rd-unescape "\\v")
                   (nelisp--rd-unescape (apply #'string '(120 92 10 121)))
                   (nelisp--rd-unescape "x\\ y")
                   (nelisp--rd-unescape "\\q")))
            '((120 0 121) (10) (65) (65) (65) (233) (233) (128512)
              (128512) (1) (1) (32) (127) (27) (7) (8) (12) (10)
              (13) (9) (11) (120 121) (120 121) (113))))
          (let ((meta (nelisp--rd-unescape "\\M-a")))
            (should (equal (string-to-list meta) '(225)))
            (should-not (multibyte-string-p meta))))
      (dolist (entry old)
        (if (nth 1 entry)
            (fset (car entry) (nth 2 entry))
          (fmakunbound (car entry)))))))

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
