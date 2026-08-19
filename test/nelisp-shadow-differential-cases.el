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
 ;; maphash reaches every entry
 (let ((h (make-hash-table :test 'equal)) (n 0))
   (puthash "b" 2 h) (puthash "a" 1 h) (puthash "c" 3 h)
   (maphash (lambda (_k v) (setq n (+ n v))) h)
   n))

;;; nelisp-shadow-differential-cases.el ends here
