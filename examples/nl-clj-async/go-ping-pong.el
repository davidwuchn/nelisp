;;; go-ping-pong.el --- nl-clj-async demo: ping/pong over channels and go blocks -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 195 (docs/design/195-clojure-compat-library.org) §4.6's own
;; honest limit, inherited from `nelisp-actor' (§2.4): a NEW `nl-clj-
;; go' form written and loaded fresh does not run on `target/nelisp'
;; without the same build-time CPS-transform + bake step `nelisp-
;; actor' itself requires -- "write a go block and ship it standalone"
;; is a two-step workflow, not a plain `require'.  This file is that
;; first step: an ordinary, host-Emacs-only example using `nl-clj-go'/
;; `nl-clj-chan'/`nl-clj-close!' -- the higher-level spawn/create/close
;; primitives -- deliberately mirroring `examples/nelisp-actor/
;; two-actor-exchange.el''s own ping-pong shape so the standalone
;; smoke's claim ("a go block IS a CPS-transformed cooperative
;; coroutine, same as a raw actor") is visibly the same demo, one
;; layer up.
;;
;; A named, real, honestly-scoped gap this file works around rather
;; than hides: the exchange itself uses `nelisp-chan-send'/`nelisp-
;; chan-recv' (the primitives `nl-clj->!'/`nl-clj-<!' themselves wrap)
;; DIRECTLY, not `nl-clj-<!'/`nl-clj->!'.  Against-the-bug, measured
;; directly across many narrowing rounds this session: a two-`nl-clj-
;; go' channel bounce built on `nl-clj-<!'/`nl-clj->!' is fully correct
;; on host Emacs (this package's own `nl-clj-async-test.el' proves it,
;; 29/29 green, including this exact producer/consumer and ping/pong
;; shape) but was measured to hang on `target/nelisp' specifically once
;; the SAME park point is resumed a second time from inside a `while'
;; loop -- reproduced in isolation with `nl-clj-<!' alone, independent
;; of `nl-clj-go', `close!', or any conditional branching, and NOT
;; reproduced by the raw `nelisp-chan-recv'/`nelisp-chan-send' macros
;; this file uses instead, which this session verified directly
;; complete correctly across many round trips on the same binary.  Not
;; root-caused further within this session's time budget -- named here
;; as a real, open, standalone-specific gap in `nl-clj-<!'/`nl-clj->!'
;; themselves (not in `nl-clj-go', not in the channel mediator, both of
;; which THIS file's own standalone smoke proves clean), not glossed
;; over as "the same thing, one layer up" the way an earlier draft of
;; this file's own Commentary claimed before this was found.
;;
;; `packages/nl-clj/scripts/nl-clj-async-cps-dump.el' (run under host
;; Emacs, real `generator.el') transforms `nl-clj-async-demo-ping-pong'
;; below -- together with `nl-clj-async--make-chan-1' itself, since a
;; channel a `go' block creates also embeds one `nelisp-actor-lambda' --
;; into `packages/nl-clj/generated/go-ping-pong-cps.el', the checked-in
;; build-time bake `nl-clj-async-standalone-smoke.el' actually loads.
;; See `make nl-clj-async-cps-baseline'.
;;
;; Unlike the two-actor-exchange demo (which deliberately leaves ping
;; permanently `:blocked-receive', waiting for a reply pong stops
;; sending), this one is written so BOTH sides terminate cleanly: each
;; side does exactly HOPS receive/reply cycles (a plain counter, not a
;; `close!'-triggered nil-unpark), symmetric on both sides -- the
;; shape this session measured to survive standalone repeatedly.

;;; Code:

(require 'nelisp)
(require 'cl-lib)
(require 'nelisp-actor)
(require 'nl-clj-core)
(require 'nl-safe)
(require 'nl-clj-async)

(defun nl-clj-async-demo-ping-pong (hops)
  "Bounce a counter between two `nl-clj-go' blocks, each talking over
its own channel, for HOPS round trips.  HOPS must be >= 1 -- ping's
own initial send has no unconditional guard around it (see this file's
Commentary: wrapping even a single, one-shot parking call in a `when'
here, to special-case HOPS = 0, was tried and itself measured to hang
standalone, so it stays unconditional and HOPS = 0 is simply not a
supported input, an accepted, narrow gap rather than a worked-around
one).  Returns a plist:

  :trail        ((ACTOR . N) ...) in the order each hop was received --
                same shape as `nelisp-demo-ping-pong''s own :trail
  :ping-result  the ping go-block's own return value (`:ping-done')
  :pong-result  likewise for pong (`:pong-done')

Both sides terminate cleanly (unlike the raw-actor demo this mirrors,
which deliberately leaves ping dangling for every HOPS value): pong
always replies exactly HOPS times; ping sends the initial value plus
exactly (HOPS - 1) replies, so the last exchange is pong's alone --
symmetric, counter-bounded termination on both sides, no `close!'
needed to unpark a final dangling receive."
  (nelisp-actor--reset)
  (let ((to-ping (nl-clj-chan))
        (to-pong (nl-clj-chan))
        (trail nil)
        pong-chan ping-chan)
    (setq pong-chan
          (nl-clj-go
            (let ((i 0))
              (while (< i hops)
                (let ((n (cadr (nelisp-chan-recv to-pong))))
                  (setq trail (cons (cons 'pong n) trail))
                  (nelisp-chan-send to-ping (1+ n)))
                (setq i (1+ i))))
            :pong-done))
    (setq ping-chan
          (nl-clj-go
            (nelisp-chan-send to-pong 0)
            (let ((i 0))
              (while (< i hops)
                (let ((n (cadr (nelisp-chan-recv to-ping))))
                  (setq trail (cons (cons 'ping n) trail))
                  (when (< (1+ i) hops)
                    (nelisp-chan-send to-pong (1+ n))))
                (setq i (1+ i))))
            :ping-done))
    (nelisp-actor-run-until-idle)
    (list :trail (nreverse trail)
          :ping-result (nl-clj-<!! ping-chan)
          :pong-result (nl-clj-<!! pong-chan))))

(provide 'nl-clj-async-go-ping-pong-demo)

;;; go-ping-pong.el ends here
