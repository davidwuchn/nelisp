;;; nelisp-native-load-fixtures.el --- artifacts for the loader check  -*- lexical-binding: t; -*-

;;; Commentary:

;; Compiles the `.neln' artifacts `test/nelisp-native-load-driver.el'
;; loads.  Host Emacs builds them; the reader runs them.  Kept beside the
;; driver so the two lists cannot drift apart unnoticed -- a missing
;; artifact fails the driver's case rather than being skipped.

;;; Code:

(require 'nelisp-artifact)

(defconst nelisp-native-load-fixtures
  '(("inc1" "(defun inc1 (x) (1+ x))")
    ("nested" "(defun nested (x) (1- (1+ (1+ x))))")
    ("carlist" "(defun carlist (x) (car (list (1+ x) 0)))")
    ("add3" "(defun add3 (a b c) (+ a (+ b c)))")
    ("zero" "(defun zero () 7)")
    ("six" "(defun six (a b c d e f) (+ a (+ b (+ c (+ d (+ e f))))))")
    ("strlen" "(defun strlen (s) (length s))")
    ("symname" "(defun symname (x) (symbol-name (quote abc)))")
    ("istrue" "(defun istrue (x) (integerp x))")
    ("isfalse" "(defun isfalse (x) (stringp x))"))
  "(NAME SOURCE) for each artifact the loader driver calls.")

(defun nelisp-native-load-fixtures-build (dir)
  "Compile every fixture into DIR as NAME.neln."
  (make-directory dir t)
  (dolist (entry nelisp-native-load-fixtures)
    (let* ((name (car entry))
           (el (expand-file-name (concat name ".el") dir))
           (neln (expand-file-name (concat name ".neln") dir)))
      (with-temp-file el
        (insert (cadr entry) "\n" (format "(provide '%s)\n" name)))
      (nelisp-artifact-compile-file el neln nil nil nil nil nil 'neln)
      (let* ((native (plist-get (nelisp-artifact--read-payload neln) :native))
             (meta (car (plist-get native :defuns))))
        (message "[fixture] %-10s arity=%s rt=%s text=%s externs=%S"
                 name (plist-get meta :arity) (plist-get meta :rt-slot-count)
                 (plist-get meta :size)
                 (plist-get native :extern-symbols))))))

(defun nelisp-native-load-fixtures-main ()
  "Entry point: build into the directory named by NELISP_ARTIFACT_DIR."
  (let ((dir (getenv "NELISP_ARTIFACT_DIR")))
    (unless dir
      (error "nelisp-native-load-fixtures: NELISP_ARTIFACT_DIR is unset"))
    (nelisp-native-load-fixtures-build dir)))

(provide 'nelisp-native-load-fixtures)

;;; nelisp-native-load-fixtures.el ends here
