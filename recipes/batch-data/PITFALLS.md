# batch-data — what bites, and how it looks when it does

## `write-region stub: wrf returned 28 (expected 20)`

The write **succeeded**. `write-region` checks its own work by comparing
a character count (20) against the byte count actually written (28), and
those differ for anything multibyte, so every correct write of Japanese
text raises this error after the file is already on disk.

Do not "fix" it by writing ASCII, and do not silence it and move on:
neither the error nor its absence is evidence. Wrap the write, read the
file back, compare. `batch-write-file` in the skeleton does exactly that.

## The output file is nowhere to be found

`/tmp/out.txt` passed to the runtime resolves against the **current
drive** — on a checkout under `D:` it becomes `D:\tmp\out.txt`, while the
same string in an MSYS shell means `%TEMP%`. Write and read agree with
each other, so the program looks correct and the round trip passes; only
the shell disagrees about where the file is.

Pass drive-qualified paths (`C:/...`), or paths relative to the working
directory.

Note that environment variables can be rewritten on the way in: MSYS
converts POSIX-looking values when spawning a native process, so
`BATCH_OUTPUT=/tmp/out.txt` from bash arrives as `C:/Users/.../Temp/out.txt`
while the same literal inside `--eval` does not. Two paths that look
identical in your source can land on different drives depending on how
they got there.

## `file-exists-p` returns nil for a file you are looking at

It is a stub in this build; so is `file-readable-p`. Verified against an
absolute drive-qualified path to a file that exists. Any code of the
form

```elisp
(when (file-exists-p out) ...)
```

is dead code here. Read the file and check what you got instead.

## `void-function: (goto-char)` / `(re-search-forward)`

Buffers exist, buffer navigation does not. `with-temp-buffer` +
`insert-file-contents` + `buffer-string` is a supported way to get a file
into a string, and after that you are in string-land: `split-string`,
`string-match`, `substring`.

## The report looks right but the characters are wrong

A mojibake round trip still produces well-formed output with plausible
counts. That is why `verify.sh` compares the multibyte key byte for byte
with `cmp` rather than eyeballing the report. Keep that check when you
adapt the recipe — visual inspection cannot distinguish these cases.

## Commas inside quoted fields

`batch-rows` splits on commas with no quoting rules, so `"Foo, Inc.",…`
becomes two fields, silently and with a plausible result. Real
accounting or inspection exports will contain such fields. Fix the
splitter before trusting the numbers.
