# stdio-service — what bites, and how it looks when it does

Symptoms first: the symptom is the part you can search for.

## `void-function: (string-search)`

You launched with `nelisp service.el` instead of `nelisp --load
service.el`. The positional form loads through a leaner substrate where
`string-search` does not exist, so the service dies on its first line.

`--load` is the supported entry point for this recipe. The subcommand
`load-elisp-source` was also tried and aborts with `form aborted without
signal (rc=1)`.

## An extra line appears after your last response

`--load` prints the loaded file's return value when it finishes. That is
not noise you can suppress, so the skeleton makes it useful: `service-main`
returns `service-eof`, and that line is the documented end-of-stream
marker. If you restructure the file, keep a deliberate final value —
otherwise the host receives whatever the last form happened to evaluate
to.

## `read: only string streams supported`

`read` cannot read from stdin here, and `standard-input` is unbound.
Read bytes with `read-stdin-bytes`, split lines yourself, and parse each
line with `read-from-string`. The skeleton's `service-next-line` does
this; the buffering is not optional, because a chunk boundary can land
mid-line.

## The host hangs waiting for a response

Check flushing before blaming the host: run `verify.sh`, whose fourth
check holds the pipe open and requires output to appear before exit. On
this tree responses flush per line. If that check ever fails, this shape
is unusable for an interactive host on that platform, and no amount of
host-side work will fix it.

## A single malformed byte kills the worker

The skeleton answers `(error "unreadable request")` instead of letting
`read-from-string` signal. Keep that. A host that can crash its worker by
sending one bad line is a host that eventually will.

## Everything works until it runs for a day

The arena does not reclaim: about 560 bytes per evaluated operation, and
`garbage-collect` frees none of it. Measured 2026-08-17. Plan for
restarts — supervision is the fix available today, not a workaround to be
embarrassed about.
