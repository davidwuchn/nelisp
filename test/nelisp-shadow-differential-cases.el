;;; nelisp-shadow-differential-cases.el --- native vs prelude, same answers -*- lexical-binding: nil; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Expressions exercising names the standalone provides natively AND the
;; prelude redefines unconditionally, so loading the prelude replaces the
;; native implementation with an Elisp one.  `make
;; standalone-reader-shadow-smoke' evaluates this file twice -- once as-is,
;; once with the prelude loaded first -- and requires the two results to be
;; identical.
;;
;; Measured 2026-08-19: 70 of the 245 `shared-shadowing' names in
;; docs/emacs-compat-table.txt are also in the standalone's native builtin
;; list, and 10 of those are defined in the prelude, which is the set both
;; halves of a run can actually reach.  Nothing here diverged when the file
;; was written; the point is that it stays that way.
;;
;; The class is not hypothetical.  Three defects on 2026-08-19 were an
;; unconditional definition landing on a working one: `provide'/`featurep'
;; fset over the native builtins while `require' stayed native, a
;; `string-match-p' that recognised five literal regexps and answered nil to
;; everything else, and an `error-message-string' that dropped the error
;; symbol.  Each was found by hand, late, a long way from where it was
;; introduced.  A differential is how a machine finds the next one.
;;
;; When comparing this file's value against stock Emacs by hand, wrap it so
;; NeLisp prints through `format "%S"' as Emacs does:
;;
;;   (princ (format "%S\n" (progn <this file>)))
;;
;; Reading the runtime's own value echo instead compares Emacs's printer
;; against a DIFFERENT NeLisp printer -- the native `nelisp--repr' -- and
;; that one does not escape a backslash inside a nested string, so
;; (prin1-to-string (intern "12")) shows as "\\12" from one and "\\\\12"
;; from the other while the value is byte-identical.  An hour went into
;; that mirage on 2026-08-19.  The echo gap is a real divergence and is its
;; own item; it is just not what these cases are about.
;;
;; Add a case when a prelude definition starts covering more ground, and
;; keep every expression answerable by BOTH implementations -- an expression
;; only the prelude can evaluate proves nothing about agreement.

;;; Code:

(list
 ;; format
 (format "%s-%d" "x" 7) (format "%S" '(1 . 2)) (format "%5.2f" 1.5)
 (format "%c%%" 65) (format "%-4s|" "ab")
 ;; substring, including the negative and empty edges
 (substring "abcdef" 1 3) (substring "abcdef" -2) (substring "abc" 0 0)
 (substring "abcdef" 2) (substring "abcdef" 0 -3)
 ;; string=
 (string= "a" "a") (string= "a" "b") (string= "" "")
 ;; the rounding family: sign matters, and each rounds a different way
 (floor 7 2) (floor -7 2) (floor 7) (ceiling 7 2) (ceiling -7 2)
 (truncate 7 2) (truncate -7 2) (truncate 7) (mod 7 2) (mod -7 2) (mod 7 -2)
 ;; equal: structure, not identity, and 1 is not 1.0
 (equal '(1 (2 3)) '(1 (2 3))) (equal "a" "a") (equal [1 2] [1 2]) (equal 1 1.0)
 (equal nil nil) (equal '(1 . 2) '(1 . 2))
 ;; natnump
 (natnump 3) (natnump 0) (natnump -1) (natnump "x")
 ;; A leading string is a docstring only when something follows it.  When it
 ;; is the whole body it IS the body -- `(defun f () "hello")' answered nil
 ;; until 2026-08-19, in both the prelude stripper and the native `defun'
 ;; the evaluator actually dispatches.  All four edges, because getting one
 ;; right by breaking another is the easy failure here.
 (progn (defun nl-diff-a () "only") (nl-diff-a))
 (progn (defun nl-diff-b () "doc" "body") (nl-diff-b))
 (progn (defun nl-diff-c (x) "doc" x) (nl-diff-c 5))
 ;; Split rather than wrapped in `progn': a call to an empty-body function
 ;; does not write its output slot, so inside a `progn' it yields whatever
 ;; the previous form left there -- `(progn (defun d () (declare ...)) (d))'
 ;; answers `d' here and nil in Emacs.  Separate list elements get separate
 ;; slots, so these two are the honest test of the declare-only body; the
 ;; slot bug is its own defect and does not belong hidden in this one.
 (defun nl-diff-d () (declare (indent 1)))
 (nl-diff-d)
 (progn (defun nl-diff-e () "doc" (declare (indent 1)) 7) (nl-diff-e))
 (progn (defmacro nl-diff-m () "mac-only") (nl-diff-m))
 ;; regexp-quote escapes exactly the eight characters Emacs's regexp syntax
 ;; treats as special.  It used to escape six more, and ( ) { } | are LITERAL
 ;; in an Emacs regexp -- the constructs are the backslashed forms -- so
 ;; escaping them built the very syntax the caller asked to be quoted away.
 ;; The match cases matter more than the strings: they are what the function
 ;; is for, and a correct-looking escape set is worthless if the engine
 ;; disagrees.
 ;; Compared with `equal' rather than returned raw, so the case turns on the
 ;; escape set rather than on how the result prints.
 ;;
 ;; (The comment here used to say `prin1' does not escape a backslash inside
 ;; a string.  That was wrong, and measuring the bytes says so: both print
 ;; \"a\\.b\\*\" as 34 97 92 92 46 98 92 92 42 34, identical.  What does
 ;; differ is the other direction -- this prints \\n and \\t where Emacs
 ;; emits a raw newline and tab -- and since both read back to the same
 ;; string, print-then-read is intact.)
 (equal (regexp-quote "(a)") "(a)")
 (equal (regexp-quote "a|b") "a|b")
 (equal (regexp-quote "a{2}") "a{2}")
 (equal (regexp-quote "a.b*") "a\\.b\\*")
 (equal (regexp-quote "[x]") "\\[x]")
 (string-match-p (regexp-quote "(a)") "x(a)y")
 (string-match-p (regexp-quote "a|b") "za|by")
 (string-match-p (regexp-quote "a.b") "zaXby")
 (string-match-p (regexp-quote "a|b") "za")
 ;; The sequence functions take the sequences Emacs takes.  `reverse' used
 ;; to walk any argument as a list, so a vector answered (nil) -- one
 ;; element, and the wrong one; `mapconcat' answered the empty string for a
 ;; vector because the walk never entered; `nreverse' signalled on a vector;
 ;; and `nconc' skipped a non-cons argument instead of making it the tail,
 ;; so the dotted-tail idiom silently lost data.
 (reverse (list 1 2 3))
 (reverse [1 2 3])
 (reverse "abc")
 (reverse nil)
 (type-of (reverse [1 2]))
 (type-of (reverse "ab"))
 (nreverse (list 1 2 3))
 (nreverse (vector 1 2 3))
 (nreverse (copy-sequence "abc"))
 ;; in place for a vector, as in Emacs: the caller's object changes
 (let ((v (vector 1 2 3))) (nreverse v) v)
 ;; and NOT in place for `reverse'
 (let ((v (vector 1 2 3))) (reverse v) v)
 (mapconcat #'identity (list "a" "b") "-")
 (mapconcat #'identity ["a" "b"] "-")
 (mapconcat #'char-to-string "abc" "-")
 (mapconcat #'identity nil "-")
 (nconc (list 1 2) 3)
 (nconc (list 1) (list 2))
 (nconc nil 5)
 (nconc (list 1) nil)
 (nconc)
 ;; pcase.  The dispatcher used to build the test `t' for any pattern head
 ;; it did not recognise, so those matched EVERYTHING -- and it recognised
 ;; `backquote' while the reader spells the head `\=`', and `comma' while the
 ;; reader spells it `\=,'.  Between them, no backquote pattern was ever
 ;; matched and every backquote clause won regardless of the value.  There
 ;; are 47 of them in this tree.
 (pcase 5 (5 'five) (_ 'other))
 (pcase 6 (5 'five) (_ 'other))
 (pcase 5 (n (list 'bound n)))
 (pcase 'a ('a 'is-a) (_ 'other))
 (pcase "x" ("x" 'sx) (_ 'other))
 (pcase '(1 2) (`(,a ,b) (list a b)) (_ 'other))
 (pcase '(1) (`(,a ,b) (list a b)) (_ 'other))
 (pcase '(1 2 3) (`(,a . ,rest) (list a rest)) (_ 'other))
 (pcase 5 ((pred integerp) 'int) (_ 'other))
 (pcase "s" ((pred integerp) 'int) (_ 'other))
 ;; `app' applies and matches the result; a guard reads a binding made
 ;; earlier in the same `and'.
 (pcase 5 ((app 1+ 6) 'six) (_ 'other))
 (pcase 5 ((app 1+ 7) 'seven) (_ 'other))
 (pcase 5 ((and n (guard (> n 3))) 'big) (_ 'small))
 (pcase 2 ((and n (guard (> n 3))) 'big) (_ 'small))
 ;; File paths.  `expand-file-name' used to concatenate and stop: no `.',
 ;; no `..', no `~', no collapsing of doubled slashes, and an empty name
 ;; came back empty.  A path it produced could not be compared with `equal'
 ;; against one Emacs produced, which for a runtime meant to host an editor
 ;; is a daily defect.
 ;;
 ;; BASE is passed explicitly rather than bound with `let': `default-
 ;; directory' is not a special variable in this runtime, so a `let' around
 ;; it does not reach `expand-file-name' and the case would measure that
 ;; instead of what it is about.  (That gap is real and is its own item.)
 (expand-file-name "a/../b" "/base/dir/")
 (expand-file-name "/a/../b" "/base/dir/")
 (expand-file-name "./a" "/base/dir/")
 (expand-file-name "a" "/base/dir/")
 (expand-file-name "/x/y" "/base/dir/")
 (expand-file-name "" "/base/dir/")
 (expand-file-name "a/" "/base/dir/")
 (expand-file-name ".." "/base/dir/")
 (expand-file-name "a/./b" "/base/dir/")
 (expand-file-name "a//b" "/base/dir/")
 (expand-file-name "x" "/base/dir")
 (directory-file-name "a//")
 (directory-file-name "a/")
 (directory-file-name "/")
 (file-name-as-directory "")
 (file-name-as-directory "a")
 (file-name-as-directory "a/")
 (file-name-sans-versions "foo.txt~")
 (file-name-sans-versions "foo.txt.~1~")
 (file-name-sans-versions "a~b.txt")
 (file-name-sans-versions "foo.txt.~1~x")
 (file-name-extension "foo.txt~")
 (file-name-extension "foo.txt")
 (file-name-extension "foo")
 (file-name-extension "foo.~12~")
 ;; A call to a function with an EMPTY body used to leave its output slot
 ;; untouched, so it answered whatever the previous form had left there:
 ;; (progn 42 (f)) was 42.  Every context that reuses a slot was affected --
 ;; progn, a let body, an if branch, or, after a while -- and it was never
 ;; about `defun': an empty `lambda' did it too.  Only a top-level call and
 ;; `list', which gives each element its own slot, came out right.
 (progn (defun nl-diff-empty ()) 42 (nl-diff-empty))
 (progn "abc" (nl-diff-empty))
 (let ((x 9)) 7 (nl-diff-empty))
 (if t (progn 42 (nl-diff-empty)) 'no)
 (or nil (progn 42 (nl-diff-empty)))
 (progn 42 (funcall (lambda ())))
 (let ((n 0)) (while (< n 1) (setq n 1)) (nl-diff-empty))
 (list 42 (nl-diff-empty))
 ;; `length' used to answer a number for anything: an improper list got the
 ;; count of its cons cells, a SYMBOL got the length of its NAME -- (length
 ;; 'foo) was 3 -- and everything else got 0, so (length 5) was 0 rather
 ;; than an error.  A record was 0 too, where Emacs counts the type tag.
 ;; The tolerant counterparts Emacs provides did not exist, which is why
 ;; they are here: without them there is no way to ask about a dotted list.
 (length (list 1 2 3))
 (length nil)
 (length [1 2 3])
 (length "abc")
 (length (record 'a 1 2))
 (condition-case e (length '(1 2 . 3)) (error e))
 (condition-case e (length 'foo) (error e))
 (condition-case e (length 5) (error e))
 (safe-length '(1 2 . 3))
 (safe-length (list 1 2))
 (safe-length nil)
 (proper-list-p '(1 2 . 3))
 (proper-list-p (list 1 2))
 (proper-list-p nil)
 (proper-list-p 5)
 ;; `default-directory' is bound to the real working directory now.  It was
 ;; unbound, so a relative name resolved against nothing and
 ;; (expand-file-name "a") answered "/a".  The value itself cannot be a case
 ;; here -- it depends on where the test runs -- so these check the shape
 ;; and the relationship, which do not.
 ;; Only the two properties that hold in BOTH: Emacs keeps this variable in
 ;; abbreviated form, so it starts with ~ there and / here, and
 ;; (expand-file-name "a") therefore does not equal (concat
 ;; default-directory "a") in Emacs.  That the value tracks the real cwd is
 ;; checked directly instead, from four different directories, since it
 ;; cannot be a fixed case in a file.
 (and (boundp 'default-directory) (stringp default-directory))
 (eq (aref default-directory (1- (length default-directory))) ?/)
 ;; CASE-FOLD and IGNORE-CASE were accepted and ignored -- the parameters
 ;; were even named `_case-fold' and `_ignore-case' to say so -- so a caller
 ;; that asked for a case-insensitive lookup got a case-sensitive one and no
 ;; indication.  It failed on plain ASCII, not just on the non-ASCII these
 ;; still cannot fold.  `compare-strings' existed only in a file the
 ;; standalone does not load, so it was void-function.
 (assoc-string "abc" '("abc"))
 (assoc-string "ABC" '("abc") t)
 (assoc-string "ABC" '("abc") nil)
 (assoc-string "A" '((a . 1)) t)
 (assoc-string "KEY" '(("key" . 1) ("other" . 2)) t)
 (assoc-string "A" '("a" "A") t)
 (assoc-string "zzz" '("abc") t)
 (string-prefix-p "AB" "abcd" t)
 (string-prefix-p "ab" "abcd")
 (string-prefix-p "" "abc")
 (string-prefix-p "abcd" "abc")
 (string-suffix-p "CD" "abcd" t)
 (string-suffix-p "" "abc")
 (compare-strings "ABC" nil nil "abc" nil nil t)
 (compare-strings "abc" nil nil "abc" nil nil)
 (compare-strings "abd" nil nil "abc" nil nil)
 (compare-strings "xabcy" 1 4 "abc" nil nil)
 (compare-strings "ab" nil nil "abc" nil nil)
 (compare-strings "abc" nil nil "ab" nil nil)
 (compare-strings "" nil nil "" nil nil)
 (compare-strings "ABD" nil nil "abc" nil nil t)
 ;; A batch of small ones, each the same shape: a parameter accepted and
 ;; dropped, or a guard that never fired.  `delete' built a fresh list so it
 ;; removed nothing from the caller's; `nthcdr' walked past a negative N and
 ;; answered nil for every negative index; `make-list' of a negative length
 ;; answered nil rather than signalling; `string-equal' fell through to
 ;; `equal' so (string-equal 5 5) was t; `string-empty-p' called nil empty
 ;; because (length nil) is 0; `copy-sequence' returned a non-sequence
 ;; unchanged, so a caller copying in order to mutate mutated the original;
 ;; and `lsh' did not exist at all.
 (let ((l (list 1 2 3))) (delete 2 l) l)
 (delete 2 (list 1 2 3))
 (delete 1 (list 1 1 2))
 (delete 1 (vector 1 2 1))
 (delete ?a "aba")
 (nth -1 '(1 2 3))
 (nth 1 '(1 2 3))
 (nthcdr -1 '(1 2 3))
 (condition-case e (make-list -1 'a) (error (car e)))
 (make-list 0 'a)
 (make-list 3 'a)
 (condition-case e (string-equal 5 5) (error (car e)))
 (string-equal "a" "a")
 (string-equal 'a "a")
 (string-empty-p nil)
 (string-empty-p "")
 (string-empty-p "x")
 (condition-case e (copy-sequence 5) (error (car e)))
 (copy-sequence (list 1 2))
 (lsh -1 -1)
 (lsh -8 -2)
 (lsh 1 4)
 (lsh 16 -2)
 (alist-get 'a '((a . 1)))
 (alist-get "a" '(("a" . 1)) nil nil #'equal)
 (alist-get 'z '((a . 1)) 'dflt)
 ;; The printer.  `print-length' and `print-level' did not exist, so both
 ;; were ignored -- and they are the only bound on output size, so a
 ;; circular structure printed until something gave out.  Symbol escaping
 ;; was per-character only, so a symbol whose whole NAME reads as a number,
 ;; or as the dot of a dotted pair, printed as that: (intern "12") printed
 ;; 12, which reads back as the integer.  A print-then-read round trip
 ;; silently changed the type, which is what the round-trip cases below are
 ;; really testing.
 (let ((print-length 2)) (prin1-to-string '(1 2 3 4)))
 (let ((print-length 2)) (prin1-to-string [1 2 3 4]))
 (let ((print-length 2)) (prin1-to-string '((1 2 3) (4 5 6) (7 8 9))))
 (let ((print-length nil)) (prin1-to-string '(1 2 3)))
 (let ((print-level 2)) (prin1-to-string '(1 (2 (3 (4))))))
 ;; print-level bounds LIST nesting only; a vector prints in full
 (let ((print-level 2)) (prin1-to-string [1 [2 [3 [4]]]]))
 (prin1-to-string (intern "12"))
 (prin1-to-string (intern "."))
 (prin1-to-string (intern ""))
 (prin1-to-string (intern "a b"))
 (prin1-to-string 'abc)
 (let ((s (intern "12"))) (eq (car (read-from-string (prin1-to-string s))) s))
 (let ((s (intern "."))) (eq (car (read-from-string (prin1-to-string s))) s))
 (let ((s (intern "a b"))) (eq (car (read-from-string (prin1-to-string s))) s))
 (type-of (car (read-from-string (prin1-to-string (intern "12")))))
 (equal (car (read-from-string (prin1-to-string "a\"b"))) "a\"b")
 (equal (car (read-from-string (prin1-to-string '(1 "a" b)))) '(1 "a" b))
 ;; An index outside a sequence used to answer nil, which is
 ;; indistinguishable from a slot that genuinely holds nil -- so reading
 ;; past the end was a silent wrong answer and a handler written for
 ;; `args-out-of-range' never fired.  `intern' took a symbol and returned
 ;; it, because the name buffer of a Symbol reads just like a Str's.
 (condition-case e (aref [1 2 3] 5) (error e))
 (condition-case e (aref [1 2 3] -1) (error e))
 (condition-case e (aref "abc" 5) (error e))
 (condition-case e (elt "abc" 5) (error e))
 (condition-case e (elt [1 2 3] 5) (error e))
 (aref [1 2 3] 1)
 (aref "abc" 1)
 (condition-case e (intern 'foo) (error e))
 (intern "nl-diff-interned")
 ;; maphash reaches every entry
 (let ((h (make-hash-table :test 'equal)) (n 0))
   (puthash "b" 2 h) (puthash "a" 1 h) (puthash "c" 3 h)
   (maphash (lambda (_k v) (setq n (+ n v))) h)
   n)
 ;; --- 2026-08-19, found by an Emacs-parity sweep rather than by hand ---
 ;; Each of these answered something Emacs does not, and answered it
 ;; silently: no error, no warning, just a different value.
 (list (car nil) (cdr nil)
       (condition-case e (car 5) (wrong-type-argument (cdr e)))
       (condition-case e (cdr 5) (wrong-type-argument (cdr e))))
 (condition-case e (symbol-value 'nelisp-parity-unbound-zz) (error e))
 (list (zerop 0.0) (zerop -0.0) (zerop 0) (zerop 1.5)
       (condition-case e (zerop "a") (wrong-type-argument (cdr e))))
 (list (round 0.5) (round 1.5) (round 2.5) (round -0.5) (round -1.5)
       (round 2.4) (round 7 2) (round -7 2) (round 5))
 (list (isnan (/ 0.0 0.0)) (isnan 1.0))
 (let ((l (list 1 2 3))) (list (nbutlast l 1) l (nbutlast (list 1 2) 9)))
 (upcase-initials "hello wORLD")
 (list (string-trim-left "xxab" "x+") (string-trim-right "abxx" "x+")
       (string-trim-left "  ab") (string-trim-right "ab  ")
       (string-trim-left "ab" "x+"))
 (list (format-message "`%s'" "q") (format-message "no quotes"))
 (list (intern-soft "zz-never-interned-parity") (intern-soft 'car))
 ;; The regexp engine: shy groups, explicit numbering, word boundaries,
 ;; non-greedy quantifiers, folding, and \N in a replacement.
 (list (string-match "\\(?:x+\\)" "xxab")
       (string-match "\\`\\(?:x+\\)" "xxab")
       (progn (string-match "\\(?2:x\\)\\(?1:a\\)" "xxab") (match-string 1 "xxab"))
       (progn (string-match "a.*?b" "axbxb") (match-string 0 "axbxb"))
       (string-match "\\ba" " a")
       (let ((case-fold-search t)) (string-match "A" "a"))
       (let ((case-fold-search nil)) (string-match "A" "a"))
       (let ((case-fold-search t)) (string-match "[a-z]" "A"))
       (let ((case-fold-search t)) (string-match "[^a-z]" "A")))
 (list (replace-regexp-in-string "\\(a\\)" "[\\1]" "a")
       (replace-regexp-in-string "a" "[\\&]" "a")
       (replace-regexp-in-string "\\(a\\)" "[\\1]" "a" nil t))
 (list (error-message-string '(error "m"))
       (error-message-string '(wrong-type-argument listp 5))
       (error-message-string '(args-out-of-range "abc" 0 9))
       (error-message-string '(arith-error))
       (error-message-string '(user-error "u")))
 (list (macroexpand-1 '(when t 1)) (macroexpand-1 '(unless t 1)))
 (list (length= (list 1 2) 2) (length< (list 1 2) 3) (length> (list 1 2) 1)
       (file-name-concat "a" "b") (string-distance "ab" "ac")
       (let ((case-fold-search t)) (char-equal ?a ?A)))

 ;; --- 2026-08-19, second parity sweep ---
 (list (condition-case e (error "msg %d" 1) (error e))
       (condition-case e (error "n=%s" 'x) (error (error-message-string e))))
 (list (concat '(97 98)) (concat [97 98]) (concat "a" '(98) [99]) (concat))
 (list (condition-case e (substring "abc" 0 9) (error e))
       (condition-case e (substring "abc" 9) (error e))
       (condition-case e (substring "abc" 2 1) (error e))
       (substring "abc" -2) (substring "abc" 1 nil) (substring "abc" 3)
       (substring "abc" 1 -1) (substring "あいう" 1 2)
       (condition-case e (substring [1 2 3] 0 9) (error e)))
 ;; Case mapping over the ranges the prelude claims: ASCII, Latin-1, Latin
 ;; Extended-A, Greek, Cyrillic.  Outside them a character passes through,
 ;; which is a stated limit -- the CJK case is here to pin that, not to
 ;; claim coverage.
 (list (upcase "aé") (downcase "AÉ") (upcase "αβγ") (downcase "ΑΒΓ")
       (upcase "абв") (downcase "АБВ") (upcase "āăą") (downcase "ĀĂĄ")
       (upcase "ß") (upcase ?ß) (upcase "あい") (capitalize "éa bÉ")
       (upcase-initials "héllo wORLD"))
 (list (string-to-number "1.5") (string-to-number "ff" 16)
       (string-to-number "12abc") (string-to-number "") (string-to-number "-1.5e3")
       (string-to-number "  12") (string-to-number "101" 2) (string-to-number "1e3")
       (string-to-number ".5") (string-to-number "-.5") (string-to-number "+3")
       (string-to-number "1.") (string-to-number "-2.") (string-to-number "0x10"))
 (list (pcase 5 ((or (and (pred integerp) n) n) n))
       (pcase 3 ((or 1 2 n) n))
       (pcase "s" ((or (pred integerp) (pred stringp)) 'ok)))
 (list (key-description (kbd "C-x")) (key-description (kbd "C-x C-f"))
       (key-description (kbd "M-x")) (key-description (kbd "SPC"))
       (key-description (kbd "a b")))

 ;; `sxhash' values are explicitly unspecified by Emacs, so what is compared
 ;; is the contract -- `equal' objects hash equal, and the answer is an
 ;; integer -- not the numbers.
 (list (= (sxhash-equal (list 1 2)) (sxhash-equal (list 1 2)))
       (= (sxhash-equal "ab") (sxhash-equal "ab"))
       (= (sxhash-equal (vector 1 "a")) (sxhash-equal (vector 1 "a")))
       (integerp (sxhash 5)) (integerp (sxhash-eq 'a)) (integerp (sxhash-eql 1.5)))

 ;; `condition-case' :success -- the clause was inert, so the protected form's
 ;; value came back instead of the handler's, which is exactly what a
 ;; `condition-case' with no handler answers.
 (list (condition-case e 5 (:success (list 'ok e)))
       (condition-case nil 5 (:success 'ran))
       (condition-case e 5 (error 'err) (:success (list 'ok e)))
       (condition-case e 5 (:success (list 'ok e)) (error 'err))
       (condition-case e (error "x") (error 'err) (:success 'ok))
       (condition-case e 5 (:success 1 2 (list 'v e)))
       (condition-case a (condition-case b 7 (:success (* b 2))) (:success (+ a 1)))
       (let ((e 99)) (list (condition-case e 5 (:success e)) e)))

 ;; `regexp-opt' is Emacs's algorithm now, so the generated TEXT is compared,
 ;; not just what it matches.
 (list (regexp-opt '("ab" "ac")) (regexp-opt '("abc")) (regexp-opt '())
       (regexp-opt '("a" "b" "c")) (regexp-opt '("a" "b" "c" "d" "e" "f"))
       (regexp-opt '("a" "bc" "b" "cd")) (regexp-opt '("axz" "byz"))
       (regexp-opt '("" "a" "ab")) (regexp-opt '("ab" "ac") t)
       (regexp-opt '("ab" "ac") "\\(?1:") (regexp-opt '("if" "then" "else") 'words)
       (regexp-opt '("car" "cdr") 'symbols)
       (regexp-opt '("defun" "defvar" "defmacro" "defconst"))
       (regexp-opt '("a." "a*" "a+")) (regexp-opt '("]" "^" "-" "a"))
       (regexp-opt '("ad" "d")) (regexp-opt '("alpha" "alpine" "alps" "beta" "betamax"))
       (regexp-opt '("0" "1" "2" "3" "7" "8" "9")))
 ;; Word and symbol edges, and syntax classes: `_' is a symbol constituent,
 ;; not a word one, which moves every \b boundary that touches it.
 (list (string-match "\\bx" "_x") (string-match "\\bx" " x") (string-match "\\bx" "ax")
       (string-match "\\w" "_") (string-match "\\w" "a")
       (string-match "\\<x" "_x") (string-match "\\<x" " x") (string-match "\\<x" "ax")
       (string-match "x\\>" "x ") (string-match "x\\>" "xa") (string-match "x\\>" "x_")
       (string-match "\\_<x" "_x") (string-match "\\_<x" " x")
       (string-match "x\\_>" "x_") (string-match "x\\_>" "x ")
       (string-match "\\Sw" "a") (string-match "\\W" "a") (string-match "\\W" " ")
       (string-match (regexp-opt '("if" "then") 'words) "x then y"))
)

;;; nelisp-shadow-differential-cases.el ends here
