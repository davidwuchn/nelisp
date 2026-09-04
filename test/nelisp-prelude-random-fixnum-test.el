;;; nelisp-prelude-random-fixnum-test.el --- the prelude LCG stays in fixnum range -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One defect, one property: `random' in `scripts/nelisp-stdlib-prelude.el'
;; must never build a value outside the fixnum range.
;;
;; It used to.  The generator is a 31-bit LCG, and it multiplied its state
;; by 1103515245 in a single step.  A state above 2089573565 makes that
;; product exceed 2^61-1, where the standalone runtime promotes it to a
;; tag-13 bignum -- and the runtime's `logand' has no bignum path, so it
;; answers `wrong-type-argument integer-or-marker-p' on a value `integerp'
;; calls an integer.  From the fixed seed the 24th call of a process is the
;; first to land there, always with the same state (2128764739) and so
;; always the same offender (2349124342504958400).  `random' therefore
;; SIGNALLED, and everything downstream of it died: the AOT artifact
;; compiler names temp files with `(random 1000000)', so
;; `compile-elisp-artifact' failed on every input large enough to reach 24
;; temp-file names -- a 3.2 MB, 78k-line bundle among them.
;;
;; The fix splits the multiplier instead of shrinking the generator:
;; 1103515245 = 16838 * 65536 + 20077, and only the low 31 bits survive the
;; mask, so the high half contributes exactly ((s * 16838) mod 2^15) * 2^16.
;; The stream is unchanged value for value -- the second test below pins
;; that against the plain recurrence -- and no intermediate now exceeds
;; 2^46.  The prelude's own comment is deliberately three lines: its text is
;; embedded verbatim in the standalone binary, and a longer one pushed
;; `binary-size-ratchet' 1999 bytes over its ceiling.
;;
;; Testing it on the host is possible because the boundary is the same
;; number on both substrates: Emacs's own `most-positive-fixnum' is 2^61-1
;; too.  Emacs simply has bignums past it and NeLisp's `logand' does not,
;; so where the standalone signals, the host silently computes -- which is
;; exactly why this has to be checked as a PROPERTY of the arithmetic
;; rather than by watching for an error.  The suite parses the prelude,
;; evaluates its real `random' under a synthetic name (the host's own
;; `random' is never touched), and rebinds the four arithmetic primitives
;; it uses to recorders for the extent of the calls.
;;
;; The standalone-side half of this evidence is entry 48 in
;; `tools/nelisp-substrate-parity-corpus.el', which calls `random' 64
;; times through every substrate the `substrate-parity-smoke' gate drives.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar nelisp-prfx-test--root
  (let ((here (or load-file-name buffer-file-name)))
    (if here
        (file-name-directory (directory-file-name (file-name-directory here)))
      default-directory))
  "Repository root, derived from this file rather than assumed.")

(defvar nelisp-prfx-test--prelude-file
  (expand-file-name "scripts/nelisp-stdlib-prelude.el" nelisp-prfx-test--root)
  "Prelude source parsed by this suite.
A variable, not a constant, so a bisect can point the same harness at
another revision of the file.")

;; The prelude's own state variable, declared special here so the extracted
;; `defun' binds and assigns the dynamic one.
(defvar nelisp--random-state 305419896)

(defun nelisp-prfx-test--guarded-defun (name)
  "Return the `(defun NAME ...)' guarded by `(unless (fboundp \\='NAME) ...)'.
Read out of `nelisp-prfx-test--prelude-file' with the real reader: the
prelude is 7000+ lines of strings and comments that no pattern match
survives."
  (let* ((src (with-temp-buffer
                (insert-file-contents nelisp-prfx-test--prelude-file)
                (buffer-string)))
         (pos 0)
         (len (length src))
         (found nil))
    (while (and (null found) (< pos len))
      (let ((r (condition-case nil (read-from-string src pos len)
                 (end-of-file nil))))
        (if (null r)
            (setq pos len)
          (setq pos (cdr r))
          (let ((form (car r)))
            (when (and (consp form)
                       (eq (car form) 'unless)
                       (equal (nth 1 form) (list 'fboundp (list 'quote name)))
                       (consp (nth 2 form))
                       (eq (car (nth 2 form)) 'defun))
              (setq found (nth 2 form)))))))
    (or found
        (error "nelisp-prfx-test: no guarded (defun %s ...) in %s"
               name nelisp-prfx-test--prelude-file))))

(defun nelisp-prfx-test--random-fn ()
  "Return the prelude's `random' as a function value under a synthetic name."
  (let* ((form (nelisp-prfx-test--guarded-defun 'random))
         (renamed (cons 'defun (cons 'nelisp-prfx--random (cddr form)))))
    (eval renamed t)
    (symbol-function 'nelisp-prfx--random)))

(defvar nelisp-prfx-test--busy nil
  "Re-entry guard: the recorders below call the very functions they replace.")

(defun nelisp-prfx-test--record-run (fn calls)
  "Call FN CALLS times, watching every arithmetic value it builds.
Returns a plist: :values the results FN returned, :escapes every
argument or result that was not a fixnum."
  (let ((escapes nil)
        (values nil)
        (orig-* (symbol-function '*))
        (orig-+ (symbol-function '+))
        (orig-logand (symbol-function 'logand))
        (orig-mod (symbol-function 'mod)))
    (cl-flet ((watch (orig args)
                (let ((r (apply orig args)))
                  (unless nelisp-prfx-test--busy
                    (let ((nelisp-prfx-test--busy t))
                      (dolist (a args)
                        (when (and (integerp a) (not (fixnump a)))
                          (push a escapes)))
                      (when (and (integerp r) (not (fixnump r)))
                        (push r escapes))))
                  r)))
      (cl-letf (((symbol-function '*)
                 (lambda (&rest args) (watch orig-* args)))
                ((symbol-function '+)
                 (lambda (&rest args) (watch orig-+ args)))
                ((symbol-function 'logand)
                 (lambda (&rest args) (watch orig-logand args)))
                ((symbol-function 'mod)
                 (lambda (&rest args) (watch orig-mod args))))
        ;; `1+', not `+': the loop counter must not be fed to the recorder.
        (let ((i 0))
          (while (< i calls)
            (push (funcall fn 1000000) values)
            (setq i (1+ i))))))
    (list :values (nreverse values) :escapes (nreverse escapes))))

(ert-deftest nelisp-prelude-random-never-leaves-fixnum-range ()
  "200 calls of the prelude `random' build no value past `most-positive-fixnum'.
Red before the 2026-09-04 fix at call 24, with 2349124342504958400 --
the exact number `compile-elisp-artifact' died on."
  (let* ((fn (nelisp-prfx-test--random-fn))
         (nelisp--random-state 305419896)
         (run (nelisp-prfx-test--record-run fn 200)))
    (should (equal (plist-get run :escapes) nil))
    (should (= (length (plist-get run :values)) 200))
    (dolist (v (plist-get run :values))
      (should (integerp v))
      (should (>= v 0))
      (should (< v 1000000)))))

(ert-deftest nelisp-prelude-random-sequence-is-the-documented-lcg ()
  "The split multiply is an encoding change, not a new generator.
Pinned against the plain recurrence so a later `simplification' that
alters the stream is caught rather than merely re-introducing the
overflow."
  (let* ((fn (nelisp-prfx-test--random-fn))
         (nelisp--random-state 305419896)
         (reference nil)
         (s 305419896)
         (i 0))
    (while (< i 200)
      (setq s (logand (+ (* s 1103515245) 12345) 2147483647))
      (push (mod s 1000000) reference)
      (setq i (1+ i)))
    (setq reference (nreverse reference))
    (let ((got nil) (j 0))
      (while (< j 200)
        (push (funcall fn 1000000) got)
        (setq j (1+ j)))
      (should (equal (nreverse got) reference)))))

(ert-deftest nelisp-prelude-random-string-reseed-stays-in-fixnum-range ()
  "The string-LIMIT reseed path is fixnum-safe too, for a long seed."
  (let* ((fn (nelisp-prfx-test--random-fn))
         (nelisp--random-state 305419896)
         (seed (make-string 512 ?z))
         (escapes nil)
         (orig-* (symbol-function '*))
         (orig-+ (symbol-function '+))
         (orig-logand (symbol-function 'logand)))
    (cl-flet ((watch (orig args)
                (let ((r (apply orig args)))
                  (unless nelisp-prfx-test--busy
                    (let ((nelisp-prfx-test--busy t))
                      (dolist (a args)
                        (when (and (integerp a) (not (fixnump a)))
                          (push a escapes)))
                      (when (and (integerp r) (not (fixnump r)))
                        (push r escapes))))
                  r)))
      (cl-letf (((symbol-function '*)
                 (lambda (&rest args) (watch orig-* args)))
                ((symbol-function '+)
                 (lambda (&rest args) (watch orig-+ args)))
                ((symbol-function 'logand)
                 (lambda (&rest args) (watch orig-logand args))))
        (funcall fn seed)))
    (should (equal escapes nil))))

(provide 'nelisp-prelude-random-fixnum-test)

;;; nelisp-prelude-random-fixnum-test.el ends here
