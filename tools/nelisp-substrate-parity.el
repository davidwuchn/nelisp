;;; nelisp-substrate-parity.el --- one probe corpus, every entry point, diffed  -*- lexical-binding: t; -*-

;;; Commentary:

;; This branch's costliest misdiagnosis: a primitive (`emacs-pid' /
;; `random') was probed in ONE substrate (`eval-elisp-source') and the
;; answer was generalized to ANOTHER (the compiled-artifact command
;; runtime), producing a wrong root-cause claim that had to be reverted.
;; Separately, nil/t canonicality diverged BETWEEN paths of the same
;; binary (`read-from-string' canonical; `intern'/`intern-soft' were not
;; -- fixed at the native level, commit 342d098cc).  Nothing else in the
;; gate set runs one probe corpus across every substrate and diffs; this
;; does.
;;
;; Corpus: `tools/nelisp-substrate-parity-corpus.el', a fixed list of
;; (INDEX TAG FORM).  Every FORM evaluates to 0 or 1 -- nondeterministic
;; primitives are wrapped in a normalized property check, never compared
;; by raw value, which is the exact shape of the regression above.
;;
;; Substrates, run through the SAME corpus (skipped gracefully, with a
;; line saying so, when the binary in front of this script lacks one):
;;   a. bare-file     target/nelisp FILE                    -- baseline
;;   b. --load        target/nelisp --load FILE
;;   c. runtime-image dump-runtime-image + eval-runtime-image
;;   d. artifact      compile-elisp-artifact --kind neln + exec-elisp-artifact
;;   e. source-cache / source-fallback
;;                    eval-elisp-source, with/without the artifact
;;                    runtime cache-enable marker (the same pair
;;                    `nelisp-performance-gate' exercises)
;;   f. host Emacs    emacs -Q --batch -l FILE               -- shared-tag only
;;
;; Substrate (a) is the baseline; every other substrate diffs against it,
;; line by line, form index by form index.  (f) diffs only the `shared'
;; part of the corpus -- `standalone-only' forms probe a NeLisp-internal
;; name or a behavior host Emacs has no reason to share.
;;
;; Every corpus form is run in ITS OWN process for EVERY substrate.  Not
;; an optimization skipped: the bare-file substrate does not have
;; `princ', `prin1', `intern-soft' or `read-from-string' bound (see form
;; 2/3/24/25/27/28 in the corpus and the ADDENDA known divergence below)
;; -- one file holding all N forms would abort at the first missing
;; function under that substrate and silently lose every later line's
;; result.  Per-form isolation is what lets a crash on form 5 still leave
;; forms 0-4 and 6-N reported.
;;
;; A crash (nonzero exit, no matching "IDX: 0/1" line in stdout) is
;; itself a valid, comparable result: "CRASH:<classification>" is a
;; string like any other, and a substrate whose form 27 crashes while the
;; baseline's does not is exactly the divergence this gate exists to
;; name.
;;
;; Accepted divergences live in `tools/substrate-parity-accepted.el',
;; shaped like `scripts/nl-ns-accepted.el': a key is
;; "INDEX\tSUBSTRATE\tBASELINE\tACTUAL" -- both sides of the divergence,
;; not just its existence -- so if either side's value changes the old
;; key stops matching, the acceptance goes stale, and the new shape comes
;; back as an unaccepted finding instead of being silently covered by an
;; entry that no longer describes the tree.  Regenerate from a reviewed
;; tree with:
;;
;;   NELISP_SUBSTRATE_PARITY_WRITE=1 emacs -Q --batch -L lisp -L src \
;;     -L scripts -l tools/nelisp-substrate-parity.el
;;
;; Usage (what `make substrate-parity-smoke' runs):
;;
;;   emacs -Q --batch -L lisp -L src -L scripts \
;;     -l tools/nelisp-substrate-parity.el -f nelisp-substrate-parity-gate-run

;;; Code:

(require 'cl-lib)

(defvar nelisp-substrate-parity--repo-root
  (let ((here (expand-file-name (or load-file-name buffer-file-name default-directory))))
    (file-name-as-directory (expand-file-name ".." (file-name-directory here))))
  "Repository root, derived from this file's own location under tools/.")

(defun nelisp-substrate-parity--path (relative)
  "Resolve RELATIVE against the repository root."
  (expand-file-name relative nelisp-substrate-parity--repo-root))

(defvar nelisp-substrate-parity--corpus-file
  (nelisp-substrate-parity--path "tools/nelisp-substrate-parity-corpus.el"))

(defvar nelisp-substrate-parity--accepted-file
  (nelisp-substrate-parity--path "tools/substrate-parity-accepted.el"))

(defvar nelisp-substrate-parity--marker-file
  (nelisp-substrate-parity--path "target/nelisp-artifact-runtime.el.nelc.enable")
  "The artifact runtime cache enable marker `nelisp-performance-gate' also
toggles to exercise the source-cache vs source-fallback pair.")

(defun nelisp-substrate-parity--nelisp-bin ()
  "Path to the standalone binary under test."
  (or (getenv "NELISP_BIN")
      (nelisp-substrate-parity--path "target/nelisp")))

(defvar nelisp-substrate-parity--emacs (or (getenv "EMACS") "emacs"))

;; Loaded once; the corpus is pure data (see its own file header).  Declared
;; here (not `require'd -- the corpus file is loaded by absolute path, not
;; through `load-path') so byte-compiling this file does not warn about a
;; free variable for every reference below.
(defvar nelisp-substrate-parity-corpus)
(load nelisp-substrate-parity--corpus-file nil t)

(defconst nelisp-substrate-parity--shim-src
  "(defun probe-emit (idx val)
  (if (fboundp 'nelisp--write-stdout-bytes)
      (nelisp--write-stdout-bytes (format \"%d: %S\\n\" idx val))
    (princ (format \"%d: %S\\n\" idx val))))
"
  "Printing shim, embeddable in any substrate.
`nelisp--write-stdout-bytes' is the one output primitive present even in
the bare-file substrate's minimal boot (measured: `princ', `prin1' and
`message' are all void-function there).  Host Emacs and the richer
NeLisp substrates fall back to `princ'.")

;; ---------------------------------------------------------------------
;; Process plumbing
;; ---------------------------------------------------------------------

(defun nelisp-substrate-parity--call (program args cwd)
  "Run PROGRAM with ARGS in CWD.  Return (EXIT STDOUT STDERR).
CWD is always a scratch directory, never the repository -- a probe that
writes its own artifacts into the tree is not a probe."
  (let* ((default-directory (file-name-as-directory cwd))
         (err-file (make-temp-file "nlsp-err-"))
         exit out err)
    (unwind-protect
        (progn
          (with-temp-buffer
            (setq exit (apply #'call-process program nil (list t err-file) nil args))
            (setq out (buffer-string)))
          (with-temp-buffer
            (insert-file-contents err-file)
            (setq err (buffer-string))))
      (ignore-errors (delete-file err-file)))
    (list exit out err)))

(defun nelisp-substrate-parity--probe-line (idx form)
  "One `probe-emit' call for corpus entry IDX/FORM, as source text."
  (format "(probe-emit %d %S)" idx form))

(defun nelisp-substrate-parity--classify (err exit)
  "Reduce ERR/EXIT to a short, machine-stable classification.
Strips anything path-shaped so the classification does not embed a
volatile temp-directory name -- otherwise every run would \"drift\" the
accepted-ledger keys even when nothing about the divergence changed.

A void-function condition is reported in at least three different
wordings measured across the CLI commands and host Emacs:
  \"nelisp: uncaught error: void-function: (X)\"          (bare/--load/image)
  \"nelisp direct artifact error: (void-function X)\"      (exec-elisp-artifact)
  \"...: symbol's function is void: X\"                    (eval-elisp-source)
  \"Symbol's function definition is void: X\"               (host Emacs)
All four are normalized to \"void-function:X\" here, so a primitive
missing identically everywhere reads as no finding -- a real
cross-substrate divergence should never hide inside a wording
difference, and a wording difference should never masquerade as one."
  (let* ((trimmed (string-trim (or err "")))
         (line (car (split-string trimmed "\n" t)))
         (sans-paths (and line (replace-regexp-in-string
                                 "/[[:graph:]]*/" "<path>/" line)))
         (case-fold-search t)
         (sym-re "\\([-A-Za-z0-9$*+=<>!?_.:]+\\)")
         (vf (and sans-paths
                 (or (and (string-match
                           (concat "void-function:? *(?" sym-re ")?") sans-paths)
                         (match-string 1 sans-paths))
                    (and (string-match
                          (concat "function\\(?: definition\\)? is void:? *" sym-re)
                          sans-paths)
                         (match-string 1 sans-paths))))))
    (cond
     (vf (format "void-function:%s" vf))
     ((and sans-paths (string-match "uncaught error: \\(.*\\)" sans-paths))
      (match-string 1 sans-paths))
     (sans-paths (substring sans-paths 0 (min (length sans-paths) 100)))
     (t (format "exit=%d no-output" exit)))))

(defun nelisp-substrate-parity--extract (idx exit out err)
  "Reduce one probe's raw (EXIT OUT ERR) to a comparable result string."
  (let ((re (format "^%d: \\([01]\\)$" idx)))
    (if (string-match re out)
        (match-string 1 out)
      (format "CRASH:%s" (nelisp-substrate-parity--classify err exit)))))

;; ---------------------------------------------------------------------
;; Substrate runners.  Each takes (CWD IDX FORM) and returns a result
;; string; setup functions below build whatever persistent state (image,
;; artifact, marker) a substrate needs once, outside the per-form loop.
;; ---------------------------------------------------------------------

(defun nelisp-substrate-parity--write-load-file (path idx form)
  (with-temp-file path
    (insert nelisp-substrate-parity--shim-src)
    (insert "\n")
    (insert (nelisp-substrate-parity--probe-line idx form))
    (insert "\n0\n")))

(defun nelisp-substrate-parity--run-bare (bin cwd idx form)
  (let ((file (expand-file-name (format "bare-%d.el" idx) cwd)))
    (nelisp-substrate-parity--write-load-file file idx form)
    (apply #'nelisp-substrate-parity--extract idx
           (nelisp-substrate-parity--call bin (list file) cwd))))

(defun nelisp-substrate-parity--run-load (bin cwd idx form)
  (let ((file (expand-file-name (format "load-%d.el" idx) cwd)))
    (nelisp-substrate-parity--write-load-file file idx form)
    (apply #'nelisp-substrate-parity--extract idx
           (nelisp-substrate-parity--call bin (list "--load" file) cwd))))

(defun nelisp-substrate-parity--run-host (cwd idx form)
  (let ((file (expand-file-name (format "host-%d.el" idx) cwd)))
    (nelisp-substrate-parity--write-load-file file idx form)
    (apply #'nelisp-substrate-parity--extract idx
           (nelisp-substrate-parity--call nelisp-substrate-parity--emacs
                                          (list "-Q" "--batch" "-l" file) cwd))))

(defun nelisp-substrate-parity--setup-runtime-image (bin cwd)
  "Dump a runtime image with the shim loaded.  Return its path, or
\(:unavailable . REASON) if `dump-runtime-image' is not usable here."
  (let ((shim-file (expand-file-name "ri-shim.el" cwd))
        (img (expand-file-name "corpus.nlri" cwd)))
    (with-temp-file shim-file (insert nelisp-substrate-parity--shim-src))
    (cl-destructuring-bind (exit _out err)
        (nelisp-substrate-parity--call
         bin (list "dump-runtime-image" img "--load" shim-file) cwd)
      (if (and (= exit 0) (file-exists-p img))
          img
        (cons :unavailable (nelisp-substrate-parity--classify err exit))))))

(defun nelisp-substrate-parity--run-runtime-image (bin cwd img idx form)
  (apply #'nelisp-substrate-parity--extract idx
         (nelisp-substrate-parity--call
          bin (list "eval-runtime-image" img
                    (nelisp-substrate-parity--probe-line idx form))
          cwd)))

(defun nelisp-substrate-parity--setup-artifact (bin cwd)
  "Compile the shim as a .neln artifact.  Return its path, or
\(:unavailable . REASON)."
  (let ((src (expand-file-name "artifact-shim.el" cwd))
        (out (expand-file-name "artifact-shim.el.neln" cwd)))
    (with-temp-file src
      (insert nelisp-substrate-parity--shim-src)
      (insert "(provide 'substrate-parity-shim)\n"))
    (cl-destructuring-bind (exit _out err)
        (nelisp-substrate-parity--call
         bin (list "compile-elisp-artifact" "--kind" "neln"
                   "--input" src "--output" out)
         cwd)
      (if (and (= exit 0) (file-exists-p out))
          out
        (cons :unavailable (nelisp-substrate-parity--classify err exit))))))

(defun nelisp-substrate-parity--run-artifact (bin cwd art idx form)
  (apply #'nelisp-substrate-parity--extract idx
         (nelisp-substrate-parity--call
          bin (list "exec-elisp-artifact" art
                    (nelisp-substrate-parity--probe-line idx form))
          cwd)))

(defun nelisp-substrate-parity--setup-source (cwd)
  "Write the shim as a source module for `eval-elisp-source'.  Return its
path; this step cannot itself be unavailable, since it only writes a
file -- unavailability of `eval-elisp-source' shows up as a CRASH result
on the first form instead."
  (let ((src (expand-file-name "source-shim.el" cwd)))
    (with-temp-file src
      (insert nelisp-substrate-parity--shim-src)
      (insert "(provide 'substrate-parity-shim)\n"))
    src))

(defun nelisp-substrate-parity--run-source (bin cwd src idx form)
  (apply #'nelisp-substrate-parity--extract idx
         (nelisp-substrate-parity--call
          bin (list "eval-elisp-source" src
                    (nelisp-substrate-parity--probe-line idx form))
          cwd)))

;; ---------------------------------------------------------------------
;; The artifact runtime cache marker.  `nelisp-performance-gate' toggles
;; the same file the same way; reused here rather than reinvented.
;; ---------------------------------------------------------------------

(defun nelisp-substrate-parity--marker-backup ()
  (when (file-exists-p nelisp-substrate-parity--marker-file)
    (with-temp-buffer
      (insert-file-contents nelisp-substrate-parity--marker-file)
      (buffer-string))))

(defun nelisp-substrate-parity--marker-remove ()
  (when (file-exists-p nelisp-substrate-parity--marker-file)
    (delete-file nelisp-substrate-parity--marker-file)))

(defun nelisp-substrate-parity--marker-restore (backup)
  (if backup
      (with-temp-file nelisp-substrate-parity--marker-file (insert backup))
    (nelisp-substrate-parity--marker-remove)))

;; ---------------------------------------------------------------------
;; Orchestration
;; ---------------------------------------------------------------------

(defconst nelisp-substrate-parity--substrate-order
  '("load" "runtime-image" "artifact" "source-cache" "source-fallback" "host")
  "Non-baseline substrates, in report order.  \"bare\" is the baseline and
is run separately, first.")

(defun nelisp-substrate-parity--run-all ()
  "Run the whole corpus across every substrate.
Return a plist :results (SUBSTRATE . ((IDX . VALUE) ...)) :skips (list of
report lines) :checked (count of form/substrate comparisons performed)."
  (let* ((bin (nelisp-substrate-parity--nelisp-bin))
         (cwd (make-temp-file "nelisp-substrate-parity-" t))
         (results nil)
         (skips nil)
         (checked 0))
    (unless (file-exists-p bin)
      (error "nelisp-substrate-parity: no binary at %s" bin))
    (unwind-protect
        (progn
          ;; -- baseline: bare-file --
          (let ((bare nil))
            (dolist (entry nelisp-substrate-parity-corpus)
              (cl-destructuring-bind (idx _tag form) entry
                (push (cons idx (nelisp-substrate-parity--run-bare bin cwd idx form))
                      bare)))
            (push (cons "bare" (nreverse bare)) results))

          ;; -- --load --
          (let ((load-res nil))
            (dolist (entry nelisp-substrate-parity-corpus)
              (cl-destructuring-bind (idx _tag form) entry
                (push (cons idx (nelisp-substrate-parity--run-load bin cwd idx form))
                      load-res)
                (setq checked (1+ checked))))
            (push (cons "load" (nreverse load-res)) results))

          ;; -- runtime-image --
          (let ((img (nelisp-substrate-parity--setup-runtime-image bin cwd)))
            (if (and (consp img) (eq (car img) :unavailable))
                (push (format "SUBSTRATE-SKIP name=runtime-image reason=%s" (cdr img)) skips)
              (let ((ri-res nil))
                (dolist (entry nelisp-substrate-parity-corpus)
                  (cl-destructuring-bind (idx _tag form) entry
                    (push (cons idx (nelisp-substrate-parity--run-runtime-image bin cwd img idx form))
                          ri-res)
                    (setq checked (1+ checked))))
                (push (cons "runtime-image" (nreverse ri-res)) results))))

          ;; -- compiled artifact --
          (let ((art (nelisp-substrate-parity--setup-artifact bin cwd)))
            (if (and (consp art) (eq (car art) :unavailable))
                (push (format "SUBSTRATE-SKIP name=artifact reason=%s" (cdr art)) skips)
              (let ((art-res nil))
                (dolist (entry nelisp-substrate-parity-corpus)
                  (cl-destructuring-bind (idx _tag form) entry
                    (push (cons idx (nelisp-substrate-parity--run-artifact bin cwd art idx form))
                          art-res)
                    (setq checked (1+ checked))))
                (push (cons "artifact" (nreverse art-res)) results))))

          ;; -- source: cache path, then fallback path --
          (let ((src (nelisp-substrate-parity--setup-source cwd))
                (backup (nelisp-substrate-parity--marker-backup)))
            (unwind-protect
                (progn
                  (unless (file-exists-p nelisp-substrate-parity--marker-file)
                    (push "SUBSTRATE-SKIP name=source-cache reason=no-runtime-cache-enable-marker-was-this-built-by-make-standalone-reader" skips))
                  (when (file-exists-p nelisp-substrate-parity--marker-file)
                    (let ((cache-res nil))
                      (dolist (entry nelisp-substrate-parity-corpus)
                        (cl-destructuring-bind (idx _tag form) entry
                          (push (cons idx (nelisp-substrate-parity--run-source bin cwd src idx form))
                                cache-res)
                          (setq checked (1+ checked))))
                      (push (cons "source-cache" (nreverse cache-res)) results)))
                  (nelisp-substrate-parity--marker-remove)
                  (let ((fallback-res nil))
                    (dolist (entry nelisp-substrate-parity-corpus)
                      (cl-destructuring-bind (idx _tag form) entry
                        (push (cons idx (nelisp-substrate-parity--run-source bin cwd src idx form))
                              fallback-res)
                        (setq checked (1+ checked))))
                    (push (cons "source-fallback" (nreverse fallback-res)) results)))
              ;; Restore exactly what was there -- this gate must not leave
              ;; the tree's own build state mutated when it exits.
              (nelisp-substrate-parity--marker-restore backup)))

          ;; -- host Emacs, shared-tag forms only --
          (let ((host-res nil))
            (dolist (entry nelisp-substrate-parity-corpus)
              (cl-destructuring-bind (idx tag form) entry
                (when (eq tag 'shared)
                  (push (cons idx (nelisp-substrate-parity--run-host cwd idx form))
                        host-res)
                  (setq checked (1+ checked)))))
            (push (cons "host" (nreverse host-res)) results)))
      (ignore-errors (delete-directory cwd t)))
    (list :results (nreverse results) :skips (nreverse skips) :checked checked)))

(defun nelisp-substrate-parity--diff (run)
  "Diff every non-baseline substrate in RUN against \"bare\".
Return a list of findings, each (IDX SUBSTRATE BASELINE ACTUAL)."
  (let* ((results (plist-get run :results))
         (baseline (cdr (assoc "bare" results)))
         (findings nil))
    (dolist (substrate nelisp-substrate-parity--substrate-order)
      (let ((rows (cdr (assoc substrate results))))
        (when rows
          (dolist (row rows)
            (let* ((idx (car row))
                   (actual (cdr row))
                   (want (cdr (assoc idx baseline))))
              (unless (equal want actual)
                (push (list idx substrate want actual) findings)))))))
    (nreverse findings)))

;; ---------------------------------------------------------------------
;; Accepted-divergence ledger.  Same shape as `scripts/nl-ns-accepted.el'.
;; ---------------------------------------------------------------------

(defun nelisp-substrate-parity--finding-key (finding)
  (cl-destructuring-bind (idx substrate baseline actual) finding
    (format "%d\t%s\t%s\t%s" idx substrate baseline actual)))

(defun nelisp-substrate-parity--load-accepted (path)
  "Return (:generated-at .. :reason .. :notes ALIST :keys HASH-TABLE)."
  (if (not (file-exists-p path))
      (list :generated-at nil :reason nil :notes nil :keys (make-hash-table :test 'equal))
    (let* ((raw (with-temp-buffer
                  (insert-file-contents path)
                  (goto-char (point-min))
                  (read (current-buffer))))
           (keys (make-hash-table :test 'equal)))
      (dolist (k (plist-get raw :keys)) (puthash k t keys))
      (list :generated-at (plist-get raw :generated-at)
            :reason (plist-get raw :reason)
            :notes (plist-get raw :notes)
            :keys keys))))

(defun nelisp-substrate-parity--write-accepted (findings path generated-at reason notes)
  "Write FINDINGS as the accepted set at PATH.  NOTES (an alist of key ->
reason) is carried over from the file being replaced; a note whose key
is no longer present is dropped along with it -- same rule and same
reason as `nl-ns-write-accepted'."
  (let* ((keys (sort (mapcar #'nelisp-substrate-parity--finding-key findings) #'string<))
         (kept nil))
    (dolist (key keys)
      (let ((note (cdr (assoc key notes))))
        (when note (push (cons key note) kept))))
    (setq kept (nreverse kept))
    (with-temp-buffer
      (insert ";; substrate-parity accepted divergences -- generated, review before commit.\n")
      (insert ";; Regenerate with NELISP_SUBSTRATE_PARITY_WRITE=1 (see the make\n")
      (insert ";; target); do not hand-add keys to silence a finding.\n")
      (insert ";;\n")
      (insert ";; Each key is \"INDEX\\tSUBSTRATE\\tBASELINE\\tACTUAL\" -- both sides\n")
      (insert ";; of the divergence, not just its existence.  If either value\n")
      (insert ";; changes the key stops matching, the old entry goes stale, and\n")
      (insert ";; the new shape comes back as an unaccepted finding instead of\n")
      (insert ";; being silently covered (the ns-gate lesson).\n")
      (insert ";;\n")
      (insert ";; :notes is an alist of key -> why THIS entry is accepted, and it\n")
      (insert ";; survives regeneration.\n")
      (prin1 (list :generated-at generated-at :reason reason :notes kept :keys keys)
             (current-buffer))
      (insert "\n")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) path nil 'quiet)))
    (length keys)))

;; ---------------------------------------------------------------------
;; Entry points
;; ---------------------------------------------------------------------

(defun nelisp-substrate-parity--print-report (run findings new stale)
  (dolist (line (plist-get run :skips))
    (princ (format "%s\n" line)))
  (when findings
    (princ (format "\n%d total divergence(s) from the bare-file baseline:\n\n" (length findings)))
    (dolist (f findings)
      (cl-destructuring-bind (idx substrate baseline actual) f
        (princ (format "  form=%d substrate=%s baseline=%s actual=%s\n"
                       idx substrate baseline actual)))))
  (when new
    (princ (format "\n%d finding(s) NOT in the accepted set:\n\n" (length new)))
    (dolist (f new)
      (princ (format "  %s\n" (nelisp-substrate-parity--finding-key f)))))
  (when stale
    (princ (format "\n%d accepted entr%s no longer match anything (stale -- drop them):\n\n"
                   (length stale) (if (= (length stale) 1) "y" "ies")))
    (dolist (k stale)
      (princ (format "  %s\n" k)))))

(defun nelisp-substrate-parity-gate-run ()
  "Entry point for `make substrate-parity-smoke'."
  (let* ((run (nelisp-substrate-parity--run-all))
         (findings (nelisp-substrate-parity--diff run))
         (accepted (nelisp-substrate-parity--load-accepted nelisp-substrate-parity--accepted-file))
         (accepted-keys (plist-get accepted :keys))
         (new (cl-remove-if (lambda (f) (gethash (nelisp-substrate-parity--finding-key f) accepted-keys))
                             findings))
         (current-keys (mapcar #'nelisp-substrate-parity--finding-key findings))
         (stale (cl-remove-if (lambda (k) (member k current-keys))
                               (let (ks) (maphash (lambda (k _v) (push k ks)) accepted-keys) ks)))
         (checked (plist-get run :checked))
         (problem-count (+ (length new) (length stale))))
    (princ (format "GATE-COUNT checked=%d findings=%d\n" checked problem-count))
    (nelisp-substrate-parity--print-report run findings new stale)
    (if (= problem-count 0)
        (progn (princ "\n[substrate-parity] PASS\n") 0)
      (progn (princ "\n[substrate-parity] FAIL\n") 1))))

;; ---------------------------------------------------------------------
;; Auto-notes for first-time regeneration.  A hand-written note carried
;; over from the file being replaced always wins (see
;; `nelisp-substrate-parity--notes-for'); this only fires for a key seen
;; for the first time, so the initial ledger is self-documenting instead
;; of landing with 100+ silent, unreasoned keys nobody reviewed.
;; ---------------------------------------------------------------------

(defconst nelisp-substrate-parity--bare-arith-bug-indices '(9 11 13 14))

(defun nelisp-substrate-parity--auto-note (finding)
  (cl-destructuring-bind (idx substrate _baseline actual) finding
    (cond
     ;; FIXED 2026-08-22 (see src/nelisp-core-fileio.el and the commit that
     ;; removed the matching keys from this ledger): the pure-source
     ;; fallback's `nelisp-core-read-file-as-string' silently returned "" for
     ;; every file -- `nl-syscall-read-file' (what it tried first) is a
     ;; `declare-function' against a "nelisp-runtime" module this tree never
     ;; implements, so it fell to a buffer-based read whose
     ;; `buffer-substring-no-properties' is a `scripts/nelisp-stdlib-prelude.el'
     ;; stub that always answers "" (no real buffer exists at that layer).
     ;; `nelisp-load-file' therefore "loaded" zero forms, so every one of
     ;; this corpus's 35 forms hit the SAME void-function on the shim's own
     ;; `probe-emit', which read as one failure rather than 35.  That symptom
     ;; is gone now that the file is actually read; this branch remains only
     ;; to describe what a NEW, genuinely-different source-fallback finding
     ;; means post-fix -- it is never the old symptom, since a regression of
     ;; the old bug reproduces as void-function on the corpus's OWN shim
     ;; function, not on a corpus-form primitive.
     ((and (equal substrate "source-fallback")
           (or (string-prefix-p "CRASH:void-function:" actual) (= idx 34)))
      "KNOWN GAP (2026-08-22, exposed by the eval-elisp-source pure-source-fallback file-read fix -- see src/nelisp-core-fileio.el): source-fallback is the only substrate whose FORM arguments (and, now that the file-read is fixed, its loaded FILE's own top-level forms too) run through the self-hosted `nelisp-eval' rather than through the native evaluator every other substrate calls directly. `nelisp--primitive-symbols' (src/nelisp-eval.el) is the list `nelisp--install-primitives' bulk-copies from native `fboundp' cells into `nelisp-eval's own function table, and it omits `floor', `%', `unibyte-string', `match-data', and `nelisp--write-stdout-bytes' -- all present natively (every other substrate agrees on the corpus's intended value), void-function only where `nelisp-eval' has to look them up itself. Not fixed here: completing `nelisp--primitive-symbols' is a separate, broader prelude-parity sweep, not a defect in the file-loading mechanism this commit repairs.")
     ((and (equal substrate "host") (= idx 8))
      "ACCEPTED (by design, class ii): NeLisp strings are Rust UTF-8 internally, so a raw byte >= 128 written through `unibyte-string' round-trips through UTF-8 re-encoding -- `aref' does not return the original byte the way host Emacs's unibyte strings do. Documented in memory feedback_nelisp_standalone_utf8_raw_byte_block. Every NeLisp substrate agrees with every other NeLisp substrate here; only the comparison against host Emacs differs, which is exactly the documented limitation.")
     ((equal substrate "host")
      "GAP vs host Emacs, consistent across every NeLisp substrate that can run this form -- not a cross-substrate NeLisp divergence. Form 20 (`emacs-pid') in particular is void-function in EVERY NeLisp substrate alike (bare, --load, runtime-image, artifact, source-cache), so it is a missing-primitive backlog item versus host Emacs, not a parity defect between NeLisp entry points.")
     ((memq idx nelisp-substrate-parity--bare-arith-bug-indices)
      "KNOWN DEFECT (2026-08-22, NEW, found by this gate): the bare-file substrate's `mod'/`%%' compute a C-style truncating remainder (sign follows the dividend) instead of Elisp's floor-based `mod' (sign follows the divisor), and `floor'/`truncate' silently ignore a 2-argument divisor and return the dividend unchanged -- a silent wrong answer, not a crash. Confirmed by direct exit-code probes outside this gate: bare `(mod 7 -3)' returns 1, not -2; bare `(floor 7 2)' returns 7, not 3. Every other substrate, including host Emacs, agrees and is correct. Not fixed here: the wrong dispatch lives in the bare-mode AOT driver's low-level arithmetic table (scripts/nelisp-standalone-build.el) and a mechanical fix deserves its own targeted before/after measurement rather than a patch guessed at from this gate.")
     (t
      "KNOWN DEFECT (2026-08-22): the bare positional FILE argument init path boots a smaller prelude than every other NeLisp entry point (--load, runtime-image, artifact, eval-elisp-source). Measured missing there and present everywhere else: intern-soft, read-from-string, princ, prin1, message, match-data, string-match, nreverse, read, random, make-temp-name. Extends the ADDENDA's pre-existing intern-soft finding (agent 1); this gate is what measured the full list. Deliberately not fixed here, per the ADDENDA's own scoping -- resolving it is a policy call (does bare-file mode gain a richer prelude, or does --load become the documented minimum) for whoever owns that entry point."))))

(defun nelisp-substrate-parity--notes-for (findings previous-notes)
  "Notes for FINDINGS: a note carried over from PREVIOUS-NOTES (hand-edited,
survives regeneration) wins; otherwise auto-generate one by root cause."
  (mapcar (lambda (f)
            (let* ((key (nelisp-substrate-parity--finding-key f))
                   (prev (cdr (assoc key previous-notes))))
              (cons key (or prev (nelisp-substrate-parity--auto-note f)))))
          findings))

(if (getenv "NELISP_SUBSTRATE_PARITY_WRITE")
    (let* ((run (nelisp-substrate-parity--run-all))
           (findings (nelisp-substrate-parity--diff run))
           (previous (nelisp-substrate-parity--load-accepted nelisp-substrate-parity--accepted-file)))
      (princ (format "wrote %d accepted key(s) to %s\n"
                     (nelisp-substrate-parity--write-accepted
                      findings nelisp-substrate-parity--accepted-file
                      (format-time-string "%Y-%m-%d")
                      "Regenerated from a reviewed tree."
                      (nelisp-substrate-parity--notes-for
                       findings (plist-get previous :notes)))
                     nelisp-substrate-parity--accepted-file))
      (kill-emacs 0))
  (when noninteractive
    (kill-emacs (nelisp-substrate-parity-gate-run))))

(provide 'nelisp-substrate-parity)

;;; nelisp-substrate-parity.el ends here
