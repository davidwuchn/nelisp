;;; nelisp-substrate-parity-corpus.el --- shared probe corpus for the substrate-parity gate  -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure data, read by `tools/nelisp-substrate-parity.el' and never evaluated
;; directly by this file.  Each entry is (INDEX TAG FORM):
;;
;;   INDEX  a stable integer identity for the entry.  Ledger keys and
;;          findings name a form by this number, so once assigned an
;;          index is never reused for a different form -- add new entries
;;          at the end, at the next unused index, rather than renumbering.
;;   TAG    `shared' -- also run against host Emacs and compared to it;
;;          `standalone-only' -- run only across the NeLisp substrates,
;;          because the form probes a NeLisp-internal name or a behavior
;;          host Emacs has no reason to share.
;;   FORM   an Elisp form.  Every form here evaluates to 0 or 1 (never a
;;          raw value): the point of this corpus is cross-substrate
;;          identity checking, not measuring an interesting number, and a
;;          normalized boolean is exactly comparable everywhere a printer
;;          exists and exactly encodable in a process exit status where
;;          one does not (see the driver's bare-substrate fallback).
;;          Nondeterministic primitives (`emacs-pid', `random',
;;          `make-temp-name') are wrapped in a property check, never
;;          compared by raw value -- this is the exact shape of the
;;          regression this gate exists for: a primitive probed in one
;;          substrate and generalized to another.

(defconst nelisp-substrate-parity-corpus
  '(
    ;; -- intern / intern-soft / read-from-string canonicality for "nil"
    ;; and "t" (fixed 2026-08-19 at the native level, commit 342d098cc;
    ;; these pin that the fix holds across every entry point, not just
    ;; the one it was measured through).
    (0  shared (if (eq (intern "nil") nil) 1 0))
    (1  shared (if (eq (intern "t") t) 1 0))
    (2  shared (if (eq (intern-soft "nil") nil) 1 0))
    (3  shared (if (eq (intern-soft "t") t) 1 0))
    (4  shared (if (eq (car (read-from-string "nil")) nil) 1 0))
    (5  shared (if (eq (car (read-from-string "t")) t) 1 0))
    ;; An uninterned symbol named "nil" is a different object from the
    ;; canonical `nil'; `eq' must say so.
    (6  shared (if (eq (make-symbol "nil") nil) 0 1))

    ;; -- length vs string-bytes / aref on a string with a raw byte >= 128.
    ;; Built with `unibyte-string' rather than a literal non-ASCII source
    ;; character, so the corpus file itself stays plain ASCII and this
    ;; probes string representation, not source-file decoding.
    (7  shared (let ((s (unibyte-string 233)))
                 (if (= (length s) (string-bytes s)) 1 0)))
    (8  shared (let ((s (unibyte-string 233)))
                 (if (= (aref s 0) 233) 1 0)))

    ;; -- mod/% sign conventions and floor/truncate pairs.
    (9  shared (if (= (mod 7 -3) -2) 1 0))
    (10 shared (if (= (% 7 -3) 1) 1 0))
    (11 shared (if (= (mod -7 3) 2) 1 0))
    (12 shared (if (= (% -7 3) -1) 1 0))
    (13 shared (if (and (= (floor 7 2) 3) (= (truncate 7 2) 3)) 1 0))
    (14 shared (if (and (= (floor -7 2) -4) (= (truncate -7 2) -3)) 1 0))

    ;; -- match-data survival across an intervening `string-match-p' call.
    ;; Fixed 2026-08-22: `string-match-p' used to share `string-match''s
    ;; body and clobber match-data, unlike host Emacs's documented
    ;; contract that `-p' leaves it untouched.  This form pins the real
    ;; correctness contract now -- md1 and md2 must be `equal' on every
    ;; substrate, matching host Emacs, not merely agreeing with each
    ;; other on a shared wrong answer.
    (15 shared (let (md1 md2)
                 (string-match "b" "abc")
                 (setq md1 (match-data))
                 (string-match-p "x" "xyz")
                 (setq md2 (match-data))
                 (if (equal md1 md2) 1 0)))

    ;; -- condition-case's error/t handler must not eat a throw meant for
    ;; an enclosing catch (fixed 2026-08-19; see
    ;; feedback_nelisp_condition_case_eats_throw).
    (16 shared (if (equal (catch 'parity-tag
                            (condition-case nil
                                (throw 'parity-tag 'ok)
                              (error 'caught-wrongly)))
                          'ok)
                   1 0))

    ;; -- equal/eq on shared quoted literals.  17 is unrelated conses
    ;; (equal, not eq).  18 is the real trap: a lambda closing over one
    ;; quoted literal, called twice, where the first call's destructive
    ;; `nreverse' corrupts what the second call sees (see
    ;; feedback_elisp_quoted_literal_nreverse_share).  On host Emacs the
    ;; second call does NOT reproduce "(3 2 1)" -- it sees the mutated
    ;; remnant of the first call's `nreverse' -- so this pins CURRENT
    ;; (surprising) behavior rather than asserting a "correct" one; the
    ;; value that matters is that every substrate lands on the same side.
    (17 shared (if (equal '(1 2 3) (list 1 2 3)) 1 0))
    (18 shared (if (equal (let ((f (lambda () (nreverse '(1 2 3)))))
                            (list (funcall f) (funcall f)))
                          (list '(3 2 1) '(3 2 1)))
                   1 0))

    ;; -- format %S print-depth behavior on a deep acyclic structure.
    ;; Built by a loop rather than a literal nested quote so the depth is
    ;; not hostage to hand-counted parens; checked by round-tripping
    ;; through `read' and by the absence of a truncation marker, which
    ;; catches an early print-level cutoff without needing the exact
    ;; printed string spelled out here.
    (19 shared (let ((data nil) (i 8))
                 (while (> i 0)
                   (setq data (list i data))
                   (setq i (1- i)))
                 (if (and (equal (read (format "%S" data)) data)
                         (not (string-match "\\.\\.\\." (format "%S" data))))
                     1 0)))

    ;; -- the WHY: emacs-pid / random probed in one substrate and
    ;; generalized to another was this branch's costliest misdiagnosis.
    ;; Normalized to a property, run through every substrate below.
    (20 shared (if (integerp (emacs-pid)) 1 0))
    (21 shared (let ((r (random 1000000)))
                 (if (and (integerp r) (>= r 0) (< r 1000000)) 1 0)))
    (22 shared (if (and (stringp (make-temp-name "x"))
                       (not (string= (make-temp-name "x") (make-temp-name "x"))))
                   1 0))

    ;; -- fboundp for a pinned list of load-bearing primitives.  This is
    ;; the substrate-divergence signature itself: the bare positional
    ;; FILE entry point does not pull in the same prelude `--load' does
    ;; (see the ADDENDA known divergence), and this is how many functions
    ;; that gap actually covers, named one at a time instead of folded
    ;; into a single aggregate count nobody can attribute.
    (23 shared (if (fboundp 'format) 1 0))
    (24 shared (if (fboundp 'princ) 1 0))
    (25 shared (if (fboundp 'prin1) 1 0))
    (26 shared (if (fboundp 'message) 1 0))
    (27 shared (if (fboundp 'intern-soft) 1 0))
    (28 shared (if (fboundp 'read-from-string) 1 0))
    (29 shared (if (fboundp 'require) 1 0))
    (30 shared (if (fboundp 'provide) 1 0))
    (31 shared (if (fboundp 'symbol-name) 1 0))
    (32 shared (if (fboundp 'match-data) 1 0))
    (33 shared (if (fboundp 'string-match) 1 0))
    ;; NeLisp-internal raw stdout primitive: host Emacs never has this
    ;; name, so it is standalone-only rather than diffed against (f).
    (34 standalone-only (if (fboundp 'nelisp--write-stdout-bytes) 1 0))

    ;; -- defvaralias, all four directions plus the documented return
    ;; value (THE nelix GATES, PART 2: `nelix-core.el:95' called this,
    ;; ordinary idiomatic Elisp, and NeLisp's standalone runtime had never
    ;; implemented it -- `void-function').  `shared': host Emacs aliases
    ;; the same way for the value cell, which is everything this form
    ;; checks; it never touches the function cell or plist, where
    ;; NeLisp's record-sharing implementation intentionally diverges from
    ;; host Emacs (see the `nl_sf_defvaralias' commentary in
    ;; `scripts/nelisp-standalone-build.el' for that trade-off).
    (35 shared (if (and (eq (defvaralias 'nelisp-parity-dva-a 'nelisp-parity-dva-b)
                            'nelisp-parity-dva-b)
                       (progn (setq nelisp-parity-dva-b 7)
                              (eq (symbol-value 'nelisp-parity-dva-a) 7))
                       (progn (setq nelisp-parity-dva-a 9)
                              (eq (symbol-value 'nelisp-parity-dva-b) 9)))
                  1 0))
    ))

(provide 'nelisp-substrate-parity-corpus)

;;; nelisp-substrate-parity-corpus.el ends here
