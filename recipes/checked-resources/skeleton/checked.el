;;; checked.el --- borrow-checked access to a shared buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; A shared mutable buffer, reached only through borrows.  `nl-defcell'
;; wraps the value in a borrow cell; `nl-with-borrow' takes a shared
;; borrow (any number may coexist) and `nl-with-borrow-mut' an exclusive
;; one.  Taking an exclusive borrow while a shared one is live signals
;; `nl-borrow-error' instead of quietly writing through an alias someone
;; else is reading.
;;
;; Dependencies are loaded by explicit path rather than `require'.  That
;; is the pattern the nl-* packages' own standalone smokes use, and it
;; stays correct across runtime versions: an older standalone binary
;; answered `require' for an absent file with the feature name — success
;; to every caller — while `featurep' stayed nil.  Current builds signal
;; `file-missing', but `load' by path never depended on that.
;;
;; The plain twin below exists only so the recipe's smoke can measure
;; what the checking costs on your machine, rather than quoting a number
;; from someone else's.

;;; Code:

(nl-defcell checked-buffer (make-vector 8 0))

(defvar checked-plain-buffer (make-vector 8 0)
  "An unchecked buffer, used only as the comparison arm in measurements.")

(defun checked-fill (n)
  "Write N into every slot of the cell, under an exclusive borrow."
  (nl-with-borrow-mut (b checked-buffer)
    (let ((i 0)
          (len (length b)))
      (while (< i len)
        (aset b i n)
        (setq i (+ i 1)))))
  n)

(defun checked-sum ()
  "Return the sum of the cell's slots, under a shared borrow."
  (nl-with-borrow (b checked-buffer)
    (let ((i 0)
          (acc 0)
          (len (length b)))
      (while (< i len)
        (setq acc (+ acc (aref b i)))
        (setq i (+ i 1)))
      acc)))

(defun checked-plain-sum ()
  "Return the sum of `checked-plain-buffer' with no borrow at all.
The comparison arm: same loop, same data shape, no checking."
  (let ((i 0)
        (acc 0)
        (len (length checked-plain-buffer)))
    (while (< i len)
      (setq acc (+ acc (aref checked-plain-buffer i)))
      (setq i (+ i 1)))
    acc))

(defun checked-conflict ()
  "Attempt an exclusive borrow while a shared borrow is live.
Returns `signalled' when the borrow checker caught it and `missed' when
it did not.  A recipe that only ever exercises the legal path proves
nothing about the checker."
  (condition-case _err
      (nl-with-borrow (_b checked-buffer)
        (nl-with-borrow-mut (_c checked-buffer)
          'missed))
    (nl-borrow-error 'signalled)))

(provide 'checked)

;;; checked.el ends here
