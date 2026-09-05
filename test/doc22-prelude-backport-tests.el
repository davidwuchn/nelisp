(require 'cl-lib)
(require 'ert)
(require 'subr-x)

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

(defun nelisp-doc22--standalone-eval (expression)
  "Evaluate EXPRESSION with the prepared standalone reader and return output."
  (let ((binary (expand-file-name "target/nelisp" default-directory)))
    (unless (file-executable-p binary)
      (ert-skip "target/nelisp is not built; standalone-reader gate owns it"))
    (with-temp-buffer
      (let ((rc (call-process binary nil t nil "--eval" expression)))
        (unless (= rc 0)
          (ert-fail (format "standalone expression failed: rc=%S output=%S"
                            rc (buffer-string))))
        (string-trim-right (buffer-string))))))

(ert-deftest nelisp-doc22-read-from-string-native-end-position-and-core-syntax ()
  "The public reader uses the native single-form cursor for core syntax."
  (should
   (equal
    (nelisp-doc22--standalone-eval
     (concat
      "(list"
      " (fboundp 'nelisp--read-all-from-string-native)"
      " (nelisp--read-all-from-string-native \"  (a b) tail\" 0 12)"
      " (read-from-string \"xx(foo)yy\" 2 7)"
      " (read-from-string \"é (a) tail\" 2)"
      " (read-from-string \"#'foo\")"
      " (read-from-string \"'foo\")"
      " (read-from-string \"`foo\")"
      " (read-from-string \",foo\")"
      " (read-from-string \",@foo\")"
      " (read \"(1 2) tail\"))"))
    (concat
     "(t ((a b) . 7) ((foo) . 7) ((a) . 5) ((function foo) . 5) "
     "((quote foo) . 4) ((` foo) . 4) ((, foo) . 4) ((,@ foo) . 5) "
     "(1 2))"))))

(ert-deftest nelisp-doc22-read-from-string-native-numbers-symbols-and-records ()
  "Native leaves, dotted pairs, escaped symbols, and records retain GNU shape."
  (should
   (equal
    (nelisp-doc22--standalone-eval
     (concat
      "(list"
      " (read-from-string \"42\") (read-from-string \"1.5\")"
      " (read-from-string \"#x10\") (read-from-string \"#b101\")"
      " (read-from-string \"(a . b)\")"
      " (symbol-name (car (read-from-string \"\\\\,\")))"
      " (read-from-string \"#s(foo 1)\")"
      " (recordp (car (read-from-string \"#s(foo 1)\"))))"))
    "((42 . 2) (1.5 . 3) (16 . 4) (5 . 5) ((a . b) . 7) \",\" (#<object> . 9) t)")))

(ert-deftest nelisp-doc22-read-from-string-native-chars-and-gnu-string-escapes ()
  "Required character literals stay native; the full string table falls back."
  (should
   (equal
    (nelisp-doc22--standalone-eval
     (concat
      "(list"
      " (read-from-string \"?a\") (read-from-string \"?\\\\C-x\")"
      " (read-from-string \"?\\\\M-x\") (read-from-string \"?\\\\^?\")"
      " (let ((cases (list"
      "  '(34 92 117 48 48 52 49 34)"
      "  '(34 92 85 48 48 48 49 70 54 48 48 34)"
      "  '(34 92 78 123 85 43 52 49 125 34)"
      "  '(34 92 120 52 49 52 34)"
      "  '(34 92 67 45 63 34) '(34 92 94 63 34)"
      "  '(34 92 77 45 120 34) '(34 92 48 49 50 34))))"
      "   (mapcar (lambda (codes)"
      "     (let ((r (read-from-string (apply #'string codes))))"
      "       (list (string-to-list (car r)) (cdr r)))) cases)))"))
    (concat
     "((97 . 2) (24 . 5) (134217848 . 5) (127 . 4) "
     "(((65) 8) ((128512) 12) ((65) 10) ((1044) 7) "
     "((127) 6) ((127) 5) ((248) 6) ((10) 6)))"))))

(ert-deftest nelisp-doc22-read-from-string-native-explicit-fallbacks-and-errors ()
  "Fallback-only syntax is correct and keeps the established error data."
  (should
   (equal
    (nelisp-doc22--standalone-eval
     (concat
      "(list"
      " (nelisp--read-all-from-string-native \"#24r10\" 0 6)"
      " (read-from-string \"#24r10\") (read-from-string \"#24rN\")"
      " (symbol-name (car (read-from-string \"##\")))"
      " (read-from-string (concat \"#@4abc\" (string 31) \"42\"))"
      ;; The old Elisp reader does not accept byte-code objects: preserve its
      ;; one-token result rather than claiming a native byte-code Sexp exists.
      " (read-from-string \"#[0 \\\"x\\\" [] 0]\")"
      " (condition-case e (read-from-string \"\") (error e))"
      " (condition-case e (read-from-string \" ;comment\\n\") (error e))"
      " (condition-case e (read-from-string \"#37r1\") (error e))"
      " (condition-case e"
      "   (read-from-string (apply #'string '(34 92 117 49 50 34)))"
      "   (error e)))"))
    (concat
     "(nil (24 . 6) (23 . 5) \"\" (42 . 9) (# . 1) "
     "(end-of-file) (end-of-file) "
     "(invalid-read-syntax \"integer, radix 37\") "
     "(invalid-read-syntax \"Short Unicode escape\"))"))))

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
