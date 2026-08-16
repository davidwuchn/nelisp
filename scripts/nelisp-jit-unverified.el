;;; nelisp-jit-unverified.el --- measure how much code the JIT sees unchecked  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every artifact passes `nelisp-artifact-compile-file' and every source
;; passes `make compile', so both are checked.  A body arriving at the
;; JIT may have come from `eval' or been assembled at runtime, and
;; neither ran on it -- that is the one gap building earlier cannot
;; close.  This measures the size of that gap over a whole run.
;;
;; Two things the first version of this got wrong, both of which made
;; the number it printed meaningless:
;;
;; - It read `nelisp-jit-check-seen' / `-flagged', which the JIT's own
;;   tests reset.  The report was whatever the last test left behind.
;;   Counting happens here now, in variables nothing else touches.
;;
;; - It left `nelisp-jit-enabled' alone, and that is nil by default, so
;;   the JIT never ran and almost nothing reached it.  A rate over a
;;   sample of one is not a rate.  The JIT is enabled here.
;;
;; The same mistake underneath both: reporting a percentage of a
;; population that was an artifact of the measurement rather than of the
;; code.  That is exactly how the Doc 170 section 8 gate would have been
;; answered wrongly, so it is worth being blunt about.
;;
;; Usage:
;;   make jit-unverified

;;; Code:

;; This preload runs before the Makefile's own
;; `(setq load-prefer-newer t)', so without setting it here the requires
;; below pick up stale .elc files and anything added since they were
;; compiled reads as void.
(setq load-prefer-newer t)

(dolist (dir '("lisp" "src" "packages/nelisp-jit/src"
               "packages/nl-prelude/src" "packages/nl-safe/src"
               "packages/nl-check/src"))
  (add-to-list 'load-path (expand-file-name dir)))

(require 'nelisp-jit nil t)
(require 'nl-check nil t)

(defvar nelisp-jit-unverified-seen 0
  "Bodies that reached the JIT.  Nothing but this file touches it.")

(defvar nelisp-jit-unverified-flagged 0
  "Of those, how many carried a finding.")

(defvar nelisp-jit-unverified-kinds
  '(must-use-discarded resource-untracked resource-leak resource-double)
  "Finding kinds counted.  Mirrors the artifact and compile gates.")

(defun nelisp-jit-unverified--tally (body)
  "Count BODY, and whether it carries a finding."
  (setq nelisp-jit-unverified-seen (1+ nelisp-jit-unverified-seen))
  (when (fboundp 'nl-check-expanded-forms)
    (let ((flagged nil))
      (dolist (finding (condition-case nil
                           (nl-check-expanded-forms body)
                         (error nil)))
        (when (memq (plist-get finding :kind) nelisp-jit-unverified-kinds)
          (setq flagged t)))
      (when flagged
        (setq nelisp-jit-unverified-flagged
              (1+ nelisp-jit-unverified-flagged))
        ;; Print it: a rate with no examples cannot be acted on, and
        ;; whether the flagged body is real code or a test's own fixture
        ;; is the entire difference between "the gap bites" and "the gap
        ;; is empty".
        (princ (format "[jit-unverified] flagged: %S
" (car body)))))))

(when (fboundp 'nelisp-jit-try-compile-lambda)
  ;; Turn the JIT on: with it off the measurement has no population.
  (when (boundp 'nelisp-jit-enabled)
    (setq nelisp-jit-enabled t))
  (advice-add 'nelisp-jit-try-compile-lambda :before
              (lambda (_env _params body)
                (nelisp-jit-unverified--tally body)))
  (add-hook
   'kill-emacs-hook
   (lambda ()
     (let ((seen nelisp-jit-unverified-seen)
           (flagged nelisp-jit-unverified-flagged))
       (princ (format "\n[jit-unverified] %d body(s) reached the JIT, %d carried a finding\n"
                      seen flagged))
       (if (= seen 0)
           (princ "[jit-unverified] no population -- nothing reached the JIT\n")
         (princ (format "[jit-unverified] %.1f%% flagged\n"
                        (/ (* 100.0 flagged) seen))))))))

;;; nelisp-jit-unverified.el ends here
