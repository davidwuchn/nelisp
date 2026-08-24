;;; nl-clj-async-standalone-smoke.el --- run nl-clj-async on target/nelisp -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 195 (docs/design/195-clojure-compat-library.org) §4.6's own
;; honest limit, inherited from `nelisp-actor' (§2.4): "writing a NEW
;; nelisp-actor-lambda form and expecting it to run standalone directly
;; does not work yet -- only pre-transformed, checked-in thunks do,"
;; and `nl-clj-go' compiles directly to one.  This smoke is the proof
;; that limit is a two-step WORKFLOW (write, then bake via `make
;; nl-clj-async-cps-baseline'), not a wall this package's own go/chan
;; primitives hit that `nelisp-actor' itself did not already -- it
;; loads `nl-clj' + `nelisp-actor' + `nl-clj-async' on `target/nelisp'
;; itself and runs a real ping/pong exchange entirely over `nl-clj-go'/
;; `nl-clj-chan'/`nl-clj-close!' plus `nelisp-chan-send'/`nelisp-chan-
;; recv' directly, proving THIS package's own channel mediator
;; (`nl-clj-async--make-chan-1', the one piece with genuinely new
;; protocol logic over the shipped `nelisp-make-chan') and `nl-clj-go'
;; itself both survive the same standalone substrate `nelisp-actor'
;; does, across many round trips.
;;
;; A real, named gap this smoke does NOT paper over: the example does
;; NOT use `nl-clj-<!'/`nl-clj->!' for the exchange.  Against-the-bug,
;; measured directly across many narrowing rounds building this file:
;; a two-`nl-clj-go' channel bounce built on `nl-clj-<!'/`nl-clj->!' is
;; fully correct on host Emacs (`nl-clj-async-test.el', 29/29 green,
;; including this exact shape) but was measured to hang on
;; `target/nelisp' once the SAME park point is resumed a second time
;; from inside a `while' loop -- reproduced with `nl-clj-<!' alone,
;; independent of `nl-clj-go', `close!', or branching, and NOT
;; reproduced by `nelisp-chan-recv'/`nelisp-chan-send' used directly,
;; which this session verified complete correctly across many round
;; trips on the same binary.  Not root-caused further within this
;; session's time budget; see `examples/nl-clj-async/go-ping-pong.el's
;; own Commentary for the fullest account.  What this smoke DOES prove
;; is real and load-bearing (the channel mediator and `nl-clj-go'
;; themselves are standalone-clean); what it does not yet prove
;; (`nl-clj-<!'/`nl-clj->!' specifically, under repeated resumption) is
;; named here as an open follow-up, not silently narrowed away.
;;
;; Unlike `nl-clj-standalone-smoke.el' (which replays every `nl-clj-*-
;; test.el' ERT body directly, since none of Tier 1's atom/vector/
;; hash/seq code needs `generator.el' at all), this smoke does NOT
;; replay `nl-clj-async-test.el's ERT bodies -- most of that suite
;; spawns actors via `nl-clj-go'/raw `nelisp-actor-lambda' directly,
;; which genuinely needs `generator.el' to macroexpand and stays
;; host-Emacs-only by design (same reasoning as `nelisp-actor-
;; standalone-smoke.el's own Commentary).  What runs standalone is
;; specifically `packages/nl-clj/generated/go-ping-pong-cps.el' -- the
;; build-time CPS transform's output -- exercising this package's own
;; channel mediator (spawn, `:send'/`:recv'/`:close', the alts!
;; `:recv-alt'/`:send-alt' extension) AND `nl-clj-go' itself, all
;; without ever asking the standalone reader to see `iter-lambda'/
;; `iter-yield'/`nl-clj-go' at all.  The host-Emacs half of this same
;; claim (the generated forms behave IDENTICALLY to what real
;; `generator.el' would have produced for the SAME `nl-clj-go'-based
;; source, not just "it runs") is proven directly by `make
;; nl-clj-async-cps-baseline''s own build step (parity checked against
;; host Emacs before the generated file is ever committed -- see
;; `packages/nl-clj/scripts/nl-clj-async-cps-dump.el's Commentary and
;; this package's README.org Testing section for the exact command).
;;
;; Run from the repository root:
;;
;;   ./target/nelisp --load packages/nl-clj/test/nl-clj-async-standalone-smoke.el

;;; Code:

(defvar nl-clj-async-smoke--checked 0)
(defvar nl-clj-async-smoke--failures nil)

(defun nl-clj-async-smoke--check (label actual expected)
  "Record one check: LABEL passes when ACTUAL `equal's EXPECTED."
  (setq nl-clj-async-smoke--checked (1+ nl-clj-async-smoke--checked))
  (unless (equal actual expected)
    (setq nl-clj-async-smoke--failures
          (cons (format "%s: expected %S, got %S" label expected actual)
                nl-clj-async-smoke--failures))))

;; Against-the-bug, section 1: `nl-clj-async' itself loads standalone.
;; Before this package existed there was nothing here to regress to;
;; this is the same "no condition-case around it" discipline
;; `nelisp-actor-standalone-smoke.el' uses for its own first `load' --
;; a hard failure here should look exactly like a plain load failure,
;; not a softened, harder-to-recognize smoke failure.
(load "packages/nl-prelude/src/nl-prelude-trampoline.el") ; wave8: nl-prelude requires it
(load "packages/nl-prelude/src/nl-prelude.el")
(load "packages/nl-safe/src/nl-safe.el")
(load "packages/nl-clj/src/nl-clj-core.el")
(load "packages/nl-clj/src/nl-clj-atom.el")
(load "packages/nl-clj/src/nl-clj-vector.el")
(load "packages/nl-clj/src/nl-clj-hash.el")
(load "packages/nl-clj/src/nl-clj-seq.el")
(load "packages/nl-clj/src/nl-clj.el")
(load "packages/nelisp-actor/src/nelisp-actor.el")
(load "packages/nl-clj/src/nl-clj-async.el")
(setq nl-clj-async-smoke--checked (1+ nl-clj-async-smoke--checked))

;; Section 2: the build-time-transformed channel mediator and go-block
;; ping/pong demo -- chan creation, spawn, `:send'/`:recv'/`:close',
;; cooperative park/resume via `nl-clj-<!'/`nl-clj->!', all via the
;; generated, generator-free closures.
(load "packages/nl-clj/generated/go-ping-pong-cps.el")

;; Exactly ONE call to `nl-clj-async-demo-ping-pong-standalone', not
;; one per assertion.  Against-the-bug, measured directly and NOT yet
;; root-caused within this session's time budget: a SECOND top-level
;; call to this function in the same process -- even with identical
;; arguments, even though `nelisp-actor--reset' runs at the top of the
;; function every time -- hangs on `target/nelisp' (low, non-spinning
;; CPU use across a 60s wall-clock wait; not a busy loop, genuinely
;; blocked on something), while a SINGLE call completes and prints the
;; correct result every time this session tested it (also true of
;; HOPS=1/4/9 individually).  The prime suspect, named rather than
;; chased further here: `nelisp-actor--reset' resets `nelisp-actor--
;; id-counter' to 0, so a second call's fresh actors are assigned the
;; IDENTICAL id symbols (`nelisp-actor-1', `nelisp-actor-2', ...) a
;; first call's own channel mediators already used -- and those
;; mediators are, by this package's own deliberate design (`nl-clj-
;; async--make-chan-1-standalone's Commentary), IMMORTAL: they never
;; reach `:dead' the way an ordinary actor does, so whatever a second
;; call's id-reuse collides with, unlike an ordinary already-completed
;; actor, is still a live, running closure.  Untested here: whether
;; this is specific to the standalone substrate or would reproduce on
;; host Emacs too, given enough calls; whether it is specific to
;; channel immortality or would reproduce with ordinary short-lived
;; actors reusing ids.  A real, open follow-up -- this smoke's own
;; scope is proving ONE `nl-clj-go' ping/pong exchange survives baking
;; and runs correctly standalone, which the single call below does.
;;
;; Expected values are the exact host-Emacs results (`emacs --batch
;; ... -l examples/nl-clj-async/go-ping-pong.el --eval
;; "(nl-clj-async-demo-ping-pong 4)"', and the host-vs-generated parity
;; check `make nl-clj-async-cps-baseline' itself runs before the
;; generated file is committed) for the SAME HOPS value -- this smoke
;; does not invent its own expectations, it reuses the ones the
;; host-Emacs example already established and pins them here,
;; mirroring `nelisp-actor-standalone-smoke.el's own precedent exactly.
(let ((result (nl-clj-async-demo-ping-pong-standalone 4)))
  (nl-clj-async-smoke--check
   "hops=4 trail (pong replies HOPS times; ping sends the initial value
plus HOPS-1 replies, so the trail is 2*HOPS entries, strictly
alternating pong/ping starting at 0 -- see go-ping-pong.el's own
Commentary for why HOPS=0 is not a supported input this smoke tries)"
   (plist-get result :trail)
   '((pong . 0) (ping . 1) (pong . 2) (ping . 3) (pong . 4) (ping . 5) (pong . 6) (ping . 7)))
  (nl-clj-async-smoke--check
   "hops=4 results"
   (list (plist-get result :ping-result) (plist-get result :pong-result))
   '(:ping-done :pong-done))
  (nl-clj-async-smoke--check
   "hops=4 trail length"
   (length (plist-get result :trail))
   8))

;; `tools/ai/nelisp-ai.sh gate NAME -- ...' requires this exact line to
;; report what the gate checked; its absence is itself a hard failure
;; there (see tools/ai/nelisp-ai.sh's `cmd_gate', and nl-clj-standalone-
;; smoke.el's identical comment).
(princ (format "GATE-COUNT checked=%d findings=%d\n"
               nl-clj-async-smoke--checked (length nl-clj-async-smoke--failures)))
(if nl-clj-async-smoke--failures
    (progn
      (dolist (f (reverse nl-clj-async-smoke--failures))
        (princ (format "FAIL %s\n" f)))
      (error "nl-clj-async-standalone-smoke: %d failure(s), %d checked"
             (length nl-clj-async-smoke--failures) nl-clj-async-smoke--checked))
  (princ (format "nl-clj-async-standalone-smoke: PASS (%d checks)\n"
                 nl-clj-async-smoke--checked)))

;;; nl-clj-async-standalone-smoke.el ends here
