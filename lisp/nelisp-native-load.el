;;; nelisp-native-load.el --- load and run a .neln in-process  -*- lexical-binding: t; -*-

;;; Commentary:

;; Doc 142 section 6.4: execute a `.neln' artifact's native code inside
;; the running reader, with no linker, no `cc', and no subprocess.
;;
;; The reader already shipped a working loader, but as a demo: the
;; artifact's bytes and its externs' addresses were baked into the binary
;; at build time, so it could run exactly one function.  Everything that
;; had to vary -- which artifact, how big, which symbols, what arity --
;; was fixed before the reader was built.
;;
;; This is the same mechanism driven by data read at run time.  It is
;; ordinary interpreted elisp because the reader exposes every primitive
;; it needs: `syscall-direct' for mmap, `ptr-read-*' / `ptr-write-*' for
;; the pages, `ptr-call' to enter the trampoline, and two builtins added
;; for the loader -- `nelisp--native-symbol-addr' for a runtime symbol's
;; address (`data-addr' is a compile-time form) and `nelisp--native-env'
;; for the environment pointer the boundary calls `frames'.
;;
;; What it does, given `FILE.neln' and a function name:
;;
;;   1. read the artifact and take :native's text, relocs and defun
;;      metadata (the file is a `;;;' header line plus one plist);
;;   2. mmap a code page sized to the text plus one 16-byte stub per
;;      extern, and a page for the boundary slots;
;;   3. copy the text, lay the stubs after it, point each stub at its
;;      runtime symbol and patch each plt32 relocation at the stub;
;;   4. build a trampoline for this defun's arity and slot count, fill
;;      the boundary slots, and enter the body past its prologue;
;;   5. box the arguments, `ptr-call' the trampoline, unbox the result.
;;
;; Limits, stated rather than discovered later: x86_64 only; a defun's
;; parameters and result must be integer, nil or t (the Sexp tags this
;; boxes); at most six parameters, since the trampoline passes them in
;; registers; and every extern must be in
;; `nelisp-native-load-bridgeable-symbols'.  `nelisp-native-load-check'
;; reports which of these an artifact fails before anything is mapped.

;;; Code:

(defconst nelisp-native-load-bridgeable-symbols
  '("nelisp_aot_builtin_call1"
    "nelisp_aot_builtin_calln"
    "nl_alloc_symbol"
    "nl_alloc_str"
    "nl_alloc_mut_str"
    "nl_mut_str_push_byte"
    "nl_mut_str_finalize"
    "nl_alloc_bytes"
    "nl_sexp_clone_into"
    "nl_alloc_vector"
    "nl_vector_slot_ptr"
    "nl_vector_set_slot"
    "nelisp_env_lookup_value")
  "Runtime symbols a stub can be pointed at, in `nelisp--native-symbol-addr' order.

The index is the contract: the builtin selects from a chain of
`data-addr' forms fixed when the reader was built, and nothing links
this list to that one.  They are asserted equal by the test suite.")

(defconst nelisp-native-load-stub-bytes 16
  "Bytes reserved per stub.  The stub itself is 12: movabs rax, imm64; jmp rax.")

(defconst nelisp-native-load-slot-bytes 32
  "Size of one Sexp slot.")

(defconst nelisp-native-load-callback-slots 12
  "Callback boundary slots, matching the object-mode hidden boundary.")

(defconst nelisp-native-load-boundary-slots
  (+ 5 nelisp-native-load-callback-slots)
  "Boundary slots a defun reserves: out, mirror, frames, scratch, name_slot, callbacks.")

(defconst nelisp-native-load-page-bytes 4096)

(defconst nelisp-native-load-artifact-format 'nelisp-private-nelc-v2
  "The artifact container format this loader reads.

A symbol, not a string: `:format' and `:object-format' read back as
symbols while `:arch' reads back as a string, and comparing the wrong
one rejects every artifact.")

(defconst nelisp-native-load-object-format 'nelisp-aot-elf-v1
  "The embedded object layout this loader knows how to map.")

(defconst nelisp-native-load-native-section-versions '(2)
  "Native-section versions whose field meanings this loader agrees with.

Doc 142 section 6.4 asks that a cache be rejected before executing any of
it when the ABI, target or artifact version does not match.  Checking the
version matters more here than for a bytecode lane: a mismatched
`.nelc' misbehaves, a mismatched `.neln' is machine code entered with the
wrong frame layout.")

;;;; Tags -------------------------------------------------------------

(defconst nelisp-native-load-tag-nil 0)
(defconst nelisp-native-load-tag-t 1)
(defconst nelisp-native-load-tag-int 2)
(defconst nelisp-native-load-tag-float 3)
(defconst nelisp-native-load-tag-symbol 4)
(defconst nelisp-native-load-tag-string 5)

(defconst nelisp-native-load-tag-vector 8)

(defconst nelisp-native-load-scratch-slots 16
  "Elements in the boundary scratch vector.

`scratch' is not a spare Sexp slot: compiled code reaches interior
storage through `nelisp-aot-compiler--scratch-slot', which emits
`(vector-ref-ptr SCRATCH INDEX)' and lowers to `nl_vector_slot_ptr'.
Handing it a zeroed slot makes that dereference a null payload, which is
a fault inside the runtime rather than a diagnosable error.

Sized past the ten levels `--top-level-literal-write-forms' can nest.")

(defconst nelisp-native-load-payload-ptr 16
  "Offset of the byte pointer in a symbol or string Sexp.")

(defconst nelisp-native-load-payload-len 24
  "Offset of the byte length in a symbol or string Sexp.")

;;;; Small helpers ----------------------------------------------------

(defun nelisp-native-load--u32le (value)
  "Return VALUE as four little-endian bytes."
  (let ((u (logand value #xffffffff)))
    (list (logand u #xff)
          (logand (ash u -8) #xff)
          (logand (ash u -16) #xff)
          (logand (ash u -24) #xff))))

(defun nelisp-native-load--byte (string index)
  "Return the INDEXth byte of STRING.

`aref', not `string-byte'.  In the standalone runtime every string is
UTF-8 internally, so a decoded byte of 137 is stored as the two bytes
194 137 and `string-byte' walks that encoding -- the text reached the
code page with every byte over 127 doubled.  `aref' indexes characters,
which for a byte string is the byte, on both this runtime and host
Emacs."
  (logand (aref string index) #xff))

(defun nelisp-native-load--digest (bytes)
  "Return the sha256 of BYTES as a lowercase hex string, or nil.

Goes through a raw buffer and `nelisp--sha256-bytes' rather than handing
the string to `nelisp--sha256'.  Strings are UTF-8 internally here, so
the string entry point digests the encoded form: it matches other
sha256 implementations on ASCII and diverges on any byte over 127, which
is most of a compiled object.

Returns nil where the byte digest is unavailable -- on host Emacs, and on
a reader built before it existed -- so a caller can skip the check rather
than fail closed against a digest it cannot compute."
  (when (fboundp 'nelisp--sha256-bytes)
    (let* ((n (length bytes))
           (buf (alloc-bytes (if (> n 0) n 1) 1))
           (i 0))
      (while (< i n)
        (ptr-write-u8 buf i (nelisp-native-load--byte bytes i))
        (setq i (1+ i)))
      (nelisp--sha256-bytes buf n))))

(defun nelisp-native-load--read-file (path)
  "Return the contents of PATH as a string."
  (cond
   ((fboundp 'nelisp--syscall-read-file)
    (nelisp--syscall-read-file path))
   ((fboundp 'rdf) (rdf path))
   (t (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

;;;; Artifact parsing -------------------------------------------------

(defun nelisp-native-load-manifest (path)
  "Return the manifest plist stored in the `.neln' artifact at PATH.
The file is one `;;;' header line followed by a single readable plist."
  (let* ((text (nelisp-native-load--read-file path))
         (nl (string-match "\n" text)))
    (unless nl
      (error "nelisp-native-load: %s has no header line" path))
    (car (read-from-string (substring text (1+ nl))))))

(defun nelisp-native-load--defun (native name)
  "Return NAME's entry in NATIVE's :defuns, or nil."
  (let ((rest (plist-get native :defuns))
        (found nil))
    (while (and rest (not found))
      (when (equal (plist-get (car rest) :name) name)
        (setq found (car rest)))
      (setq rest (cdr rest)))
    found))

;;;; Pre-flight -------------------------------------------------------

(defun nelisp-native-load-check (manifest name)
  "Return a list of reasons NAME in MANIFEST cannot be loaded, or nil.
Called before anything is mapped, so a refusal costs no pages and names
every problem at once rather than the first one hit."
  (let* ((native (plist-get manifest :native))
         (meta (and native (nelisp-native-load--defun native name)))
         (externs (plist-get native :extern-symbols))
         (problems nil))
    (cond
     ((not (eq (plist-get manifest :kind) 'neln))
      (setq problems (cons (list :not-neln (plist-get manifest :kind)) problems)))
     ((null native)
      (setq problems (cons (list :no-native-object) problems))))
    ;; Container format, before anything inside it is trusted.
    (unless (equal (plist-get manifest :format)
                   nelisp-native-load-artifact-format)
      (setq problems (cons (list :artifact-format (plist-get manifest :format))
                           problems)))
    (when native
      (unless (equal (plist-get native :arch) "x86_64")
        (setq problems (cons (list :arch (plist-get native :arch)) problems)))
      (unless (equal (plist-get native :object-format)
                     nelisp-native-load-object-format)
        (setq problems (cons (list :object-format
                                   (plist-get native :object-format))
                             problems)))
      (unless (memq (plist-get native :native-section-version)
                    nelisp-native-load-native-section-versions)
        (setq problems (cons (list :native-section-version
                                   (plist-get native :native-section-version))
                             problems)))
      ;; The decoded text must be exactly as long as the artifact says.  A
      ;; short read or a mangled base64 otherwise reaches the code page as
      ;; a truncated function, which is a jump into whatever follows it.
      (let ((declared (plist-get native :text-size))
            (actual (and (plist-get native :text-base64)
                         (length (base64-decode-string
                                  (plist-get native :text-base64))))))
        (unless (and (integerp declared) actual (= declared actual))
          (setq problems (cons (list :text-size-mismatch declared actual)
                               problems))))
      ;; Doc 142 section 6.4's artifact-hash check.  `:object-sha256'
      ;; covers the embedded object, so this verifies the artifact was not
      ;; corrupted or edited between compile and load -- the text the
      ;; loader maps comes out of the same manifest.
      ;;
      ;; Through `nelisp--sha256-bytes', never `nelisp--sha256': the latter
      ;; takes a string and digests its internal UTF-8, so it agrees on
      ;; ASCII and disagrees on any byte over 127.  Measured before this
      ;; existed: an object hashed the string way gave a5d68054... where
      ;; every other sha256 gives ddc6b64d...
      (let ((declared (plist-get native :object-sha256))
            (encoded (plist-get native :object-base64)))
        (when (and (stringp declared) (stringp encoded)
                   (fboundp 'nelisp--sha256-bytes))
          (let ((actual (nelisp-native-load--digest
                         (base64-decode-string encoded))))
            (unless (equal declared actual)
              (setq problems (cons (list :object-hash-mismatch declared actual)
                                   problems))))))
      ;; An empty extern set reads back as the symbol nil, not the empty list.
      (when (and externs (not (and (symbolp externs) (null externs))))
        (let ((rest externs)
              (bad nil))
          (while rest
            (unless (member (car rest) nelisp-native-load-bridgeable-symbols)
              (setq bad (cons (car rest) bad)))
            (setq rest (cdr rest)))
          (when bad
            (setq problems (cons (cons :unbridgeable bad) problems))))))
    (if (not meta)
        (cons (list :no-such-defun name) problems)
      (unless (eq (plist-get meta :param-class) 'gp)
        (setq problems (cons (list :param-class (plist-get meta :param-class))
                             problems)))
      (when (> (plist-get meta :arity) 6)
        (setq problems (cons (list :arity-over-six (plist-get meta :arity))
                             problems)))
      (unless (integerp (plist-get meta :body-offset))
        (setq problems (cons (list :no-body-offset) problems)))
      problems)))

;;;; Trampoline -------------------------------------------------------

(defconst nelisp-native-load--arg-regs '(rdi rsi rdx rcx r8 r9))

(defconst nelisp-native-load--mov-rbp-specs
  '((rax #x48 #x45 #x85)
    (rcx #x48 #x4d #x8d)
    (rdx #x48 #x55 #x95)
    (rsi #x48 #x75 #xb5)
    (rdi #x48 #x7d #xbd)
    (r8 #x4c #x45 #x85)
    (r9 #x4c #x4d #x8d))
  "REX and ModRM bytes for `mov [rbp+disp], REG', 8-bit and 32-bit forms.")

(defun nelisp-native-load--mov-rbp-disp-reg (reg disp)
  "Return the bytes of `mov [rbp+DISP], REG'."
  (let ((spec (assq reg nelisp-native-load--mov-rbp-specs)))
    (unless spec
      (error "nelisp-native-load: no encoding for register %S" reg))
    (let ((rex (nth 1 spec))
          (modrm8 (nth 2 spec))
          (modrm32 (nth 3 spec))
          (short (and (<= -128 disp) (<= disp 127))))
      (append (list rex #x89 (if short modrm8 modrm32))
              (if short
                  (list (logand disp #xff))
                (nelisp-native-load--u32le disp))))))

(defun nelisp-native-load--slot-disp (index)
  "Return the rbp-relative displacement of spill slot INDEX."
  (- (* 8 (1+ index))))

(defun nelisp-native-load--frame-bytes (arity rt-slot-count)
  "Return the synthetic frame size for ARITY parameters and RT-SLOT-COUNT slots."
  (let ((rt-rounded (if (= rt-slot-count 0)
                        0
                      (if (= (logand rt-slot-count 1) 0)
                          rt-slot-count
                        (1+ rt-slot-count)))))
    (+ (* 8 arity)
       (if (= (logand arity 1) 1) 8 0)
       (* 8 rt-rounded))))

(defun nelisp-native-load--trampoline (arity rt-slot-count)
  "Return (:bytes B :imm64-offsets O) for a defun of ARITY and RT-SLOT-COUNT.

The trampoline builds the frame the compiled body expects: it spills the
incoming register arguments to their slots, fills the boundary slots
from immediates patched in after the bytes are placed, and jumps to the
body past its own prologue.  There is one immediate per boundary slot
plus one for the entry address."
  (when (> arity (length nelisp-native-load--arg-regs))
    (error "nelisp-native-load: arity %d exceeds the register arguments" arity))
  (let ((bytes nil)
        (imm64-offsets nil)
        (frame-bytes (nelisp-native-load--frame-bytes arity rt-slot-count))
        (i 0))
    ;; push rbp; mov rbp, rsp
    (setq bytes (list #x55 #x48 #x89 #xe5))
    (when (> frame-bytes 0)
      (setq bytes (append bytes
                          (append (list #x48 #x81 #xec)
                                  (nelisp-native-load--u32le frame-bytes)))))
    (while (< i arity)
      (setq bytes (append bytes
                          (nelisp-native-load--mov-rbp-disp-reg
                           (nth i nelisp-native-load--arg-regs)
                           (nelisp-native-load--slot-disp i))))
      (setq i (1+ i)))
    (setq i 0)
    (while (< i nelisp-native-load-boundary-slots)
      ;; movabs rax, <patched>; mov [rbp+disp], rax
      (setq imm64-offsets (cons (+ (length bytes) 2) imm64-offsets))
      (setq bytes (append bytes (list #x48 #xb8 0 0 0 0 0 0 0 0)))
      (setq bytes (append bytes
                          (nelisp-native-load--mov-rbp-disp-reg
                           'rax
                           (nelisp-native-load--slot-disp (+ arity i)))))
      (setq i (1+ i)))
    ;; movabs rax, <entry>; jmp rax
    (setq imm64-offsets (cons (+ (length bytes) 2) imm64-offsets))
    (setq bytes (append bytes (list #x48 #xb8 0 0 0 0 0 0 0 0 #xff #xe0)))
    (list :bytes bytes :imm64-offsets (nreverse imm64-offsets))))

;;;; Memory -----------------------------------------------------------

(defun nelisp-native-load--page-round (n)
  "Round N up to whole pages, with a floor of one page."
  (let ((pages (/ (+ n (- nelisp-native-load-page-bytes 1))
                  nelisp-native-load-page-bytes)))
    (* nelisp-native-load-page-bytes (if (< pages 1) 1 pages))))

(defun nelisp-native-load--mmap (size executable)
  "Map SIZE bytes anonymously, executable when EXECUTABLE."
  (let ((addr (syscall-direct 9 0 size (if executable 7 3) 34 -1 0)))
    (when (< addr nelisp-native-load-page-bytes)
      (error "nelisp-native-load: mmap of %d bytes failed (%d)" size addr))
    addr))

(defun nelisp-native-load--poke-bytes (addr offset bytes)
  "Write the list BYTES into ADDR at OFFSET."
  (let ((i offset)
        (rest bytes))
    (while rest
      (ptr-write-u8 addr i (car rest))
      (setq i (1+ i))
      (setq rest (cdr rest)))))

(defun nelisp-native-load--poke-string (addr offset string)
  "Write STRING's bytes into ADDR at OFFSET."
  (let ((i 0)
        (n (length string)))
    (while (< i n)
      (ptr-write-u8 addr (+ offset i) (nelisp-native-load--byte string i))
      (setq i (1+ i)))))

(defun nelisp-native-load--zero-slot (addr)
  "Write nil (four zero words) into the Sexp slot at ADDR."
  (ptr-write-u64 addr 0 0)
  (ptr-write-u64 addr 8 0)
  (ptr-write-u64 addr 16 0)
  (ptr-write-u64 addr 24 0))

;;;; Boxing -----------------------------------------------------------

(defun nelisp-native-load--string-bytes (string)
  "Return STRING's bytes, refusing anything that is not one byte per character.
`aref' gives a character; the runtime stores strings UTF-8 internally, so
a character over 255 is more than one byte on the other side and writing
its low byte would hand the runtime a different string than was asked
for.  Refusing is the honest option until this encodes."
  (let ((i 0)
        (n (length string))
        (bytes nil))
    (while (< i n)
      (let ((c (aref string i)))
        (when (> c 255)
          (error "nelisp-native-load: %S has a character past 255 at %d"
                 string i))
        (setq bytes (cons c bytes)))
      (setq i (1+ i)))
    (nreverse bytes)))

(defun nelisp-native-load-box (addr value)
  "Write VALUE into the Sexp slot at ADDR and return ADDR.

Integers, nil, t and single-byte strings.  A string is materialized by
the runtime's own `nl_alloc_str', reached through the same stub
mechanism the loaded code uses, so the result is a string the runtime
owns rather than a slot this pretends is one.

Anything else is refused rather than written as a raw word: the runtime
takes a slot as a pointer and would dereference it."
  (cond
   ((integerp value)
    (nelisp-native-load--zero-slot addr)
    (ptr-write-u64 addr 0 nelisp-native-load-tag-int)
    (ptr-write-u64 addr 8 value))
   ((null value)
    (nelisp-native-load--zero-slot addr)
    (ptr-write-u64 addr 0 nelisp-native-load-tag-nil))
   ((eq value t)
    (nelisp-native-load--zero-slot addr)
    (ptr-write-u64 addr 0 nelisp-native-load-tag-t))
   ((stringp value)
    (let* ((bytes (nelisp-native-load--string-bytes value))
           (len (length bytes))
           ;; One byte minimum: a zero-length allocation has no address
           ;; to hand the runtime.
           (buf (alloc-bytes (if (> len 0) len 1) 1)))
      (nelisp-native-load--poke-bytes buf 0 bytes)
      (nelisp-native-load--zero-slot addr)
      (ptr-call (nelisp-native-load--symbol-addr "nl_alloc_str")
                buf len addr 0 0 0)))
   (t (error "nelisp-native-load: cannot box %S" value)))
  addr)

(defun nelisp-native-load-unbox (addr)
  "Return the value in the Sexp slot at ADDR.

Symbols come back interned and strings as their bytes.  A float is
refused: its payload is raw f64 bits and turning those back into a
number needs arithmetic this does not do, so returning the bit pattern
as an integer would be a wrong answer rather than a missing one."
  (let ((tag (ptr-read-u64 addr 0)))
    (cond
     ((= tag nelisp-native-load-tag-nil) nil)
     ((= tag nelisp-native-load-tag-t) t)
     ((= tag nelisp-native-load-tag-int) (ptr-read-u64 addr 8))
     ((= tag nelisp-native-load-tag-string)
      (nelisp-native-load--payload-string addr))
     ((= tag nelisp-native-load-tag-symbol)
      (intern (nelisp-native-load--payload-string addr)))
     ((= tag nelisp-native-load-tag-float)
      (error "nelisp-native-load: float results are not decoded"))
     (t (error "nelisp-native-load: result tag %d is not one this unboxes" tag)))))

(defun nelisp-native-load--payload-string (addr)
  "Return the byte payload of the symbol or string Sexp at ADDR."
  (let ((ptr (ptr-read-u64 addr nelisp-native-load-payload-ptr))
        (len (ptr-read-u64 addr nelisp-native-load-payload-len))
        (chars nil)
        (i 0))
    (when (= ptr 0)
      (error "nelisp-native-load: payload pointer is null"))
    (while (< i len)
      (setq chars (cons (ptr-read-u8 ptr i) chars))
      (setq i (1+ i)))
    (apply (function unibyte-string) (nreverse chars))))

;;;; Loading ----------------------------------------------------------

(defun nelisp-native-load--make-scratch-vector (addr)
  "Write a fresh scratch vector Sexp into the slot at ADDR.

`nl_alloc_vector' returns the NlVector box; the Sexp that names it is
tag 8 with the box at payload+8, which is the shape the reader's own
`nl_logic_build_scratch' builds and the shape `nl_vector_slot_ptr'
expects -- it derefs payload+8 to reach the box."
  (let ((box (ptr-call (nelisp-native-load--symbol-addr "nl_alloc_vector")
                       nelisp-native-load-scratch-slots 0 0 0 0 0))
        (set-slot (nelisp-native-load--symbol-addr "nl_vector_set_slot"))
        (i 0))
    (when (or (not (integerp box)) (= box 0))
      (error "nelisp-native-load: scratch vector allocation returned %S" box))
    ;; Every element has to hold a POINTER, not an immediate.
    ;;
    ;; `nl_vector_slot_ptr' returns the stored word when it is a pointer
    ;; and a FRESH temporary box when it is an immediate.  Compiled code
    ;; fills an element by calling it once to get somewhere to write the
    ;; value, then again to hand that same storage to
    ;; `nl_vector_set_slot' -- which only works if the two calls return
    ;; the same address.  Over an immediate they return two throwaways,
    ;; the value is written into the first and the second is copied out,
    ;; and `(vector 7 8 9)' comes back as three Nils.
    ;;
    ;; So the element cannot be nil, t or an integer: `nl_val_clone_into'
    ;; folds exactly those three back into an immediate word.  A string
    ;; takes the rebox path instead and leaves a pointer behind.
    (while (< i nelisp-native-load-scratch-slots)
      (let ((cell (alloc-bytes 32 8)))
        (nelisp-native-load-box cell "s")
        (ptr-call set-slot box i cell 0 0 0))
      (setq i (1+ i)))
    (ptr-write-u64 addr 0 nelisp-native-load-tag-vector)
    (ptr-write-u64 addr 8 box)
    (ptr-write-u64 addr 16 0)
    (ptr-write-u64 addr 24 0)
    addr))

(defun nelisp-native-load-abi (native)
  "Return `boxed' or `integer' for the unit NATIVE's calling convention.

The artifact metadata does not record this -- the CLI decides by trying
the integer call and falling back when it fails, which is not available
in-process because a wrong guess corrupts rather than errors.  So it is
derived: a defun reaches the boxed boundary only by calling through it,
and every such call leaves an extern behind.  With no externs there is
nothing for the boundary to do, and the parameters arrive as raw i64
with the result in rax.

The consequence of the derivation being wrong is silent arithmetic on
the wrong values, so a caller that knows better should override :abi in
the handle rather than trust this."
  (let ((externs (plist-get native :extern-symbols)))
    (if (or (null externs) (and (symbolp externs) (null externs)))
        'integer
      'boxed)))

(defun nelisp-native-load--symbol-addr (name)
  "Return the runtime address of NAME."
  (let ((rest nelisp-native-load-bridgeable-symbols)
        (idx 0)
        (found nil))
    (while (and rest (not found))
      (if (equal (car rest) name)
          (setq found idx)
        (setq idx (1+ idx)))
      (setq rest (cdr rest)))
    (unless found
      (error "nelisp-native-load: no bridge for %s" name))
    (let ((addr (nelisp--native-symbol-addr found)))
      (when (= addr 0)
        (error "nelisp-native-load: %s resolved to 0" name))
      addr)))

(defun nelisp-native-load-artifact (path name)
  "Map NAME from the `.neln' at PATH and return a callable handle.

The handle is a plist with :entry (the trampoline address), :slots (the
boundary slot region), :arity and :arg-slots.  Pages are never unmapped:
a loaded function stays callable for the life of the process, which is
what a cache wants and what the demo did."
  (let* ((manifest (nelisp-native-load-manifest path))
         (problems (nelisp-native-load-check manifest name)))
    (when problems
      (error "nelisp-native-load: cannot load %s from %s: %S" name path problems))
    (let* ((native (plist-get manifest :native))
           (meta (nelisp-native-load--defun native name))
           (text (base64-decode-string (plist-get native :text-base64)))
           (text-length (length text))
           (relocs (plist-get native :relocs))
           (externs (let ((e (plist-get native :extern-symbols)))
                      (if (and (symbolp e) (null e)) nil e)))
           (arity (plist-get meta :arity))
           (rt-slot-count (plist-get meta :rt-slot-count))
           (body-entry (+ (plist-get meta :offset) (plist-get meta :body-offset)))
           ;; Stubs sit after the text, 16-byte aligned, so a function of
           ;; any length clears the stubs it needs.
           (stub-base (* 16 (/ (+ text-length 15) 16)))
           (stub-offsets nil)
           (code-size (nelisp-native-load--page-round
                       (+ stub-base
                          (* nelisp-native-load-stub-bytes (length externs)))))
           (codepage (nelisp-native-load--mmap code-size t))
           (env (nelisp--native-env))
           (arg-slot-base (+ (* 32 5)
                             (* 32 nelisp-native-load-callback-slots)))
           (slots-size (nelisp-native-load--page-round
                        (+ arg-slot-base (* 32 (if (> arity 0) arity 1)))))
           (slots (nelisp-native-load--mmap slots-size nil))
           (trampoline (nelisp-native-load--trampoline arity rt-slot-count))
           (tramp-bytes (plist-get trampoline :bytes))
           (trampage (nelisp-native-load--mmap
                      (nelisp-native-load--page-round (length tramp-bytes)) t))
           (i 0))
      ;; Code page: text, then one stub per extern pointed at its symbol.
      (nelisp-native-load--poke-string codepage 0 text)
      (let ((rest externs)
            (idx 0))
        (while rest
          (let ((offset (+ stub-base (* nelisp-native-load-stub-bytes idx))))
            (setq stub-offsets (cons (cons (car rest) offset) stub-offsets))
            (nelisp-native-load--poke-bytes
             codepage offset '(#x48 #xb8 0 0 0 0 0 0 0 0 #xff #xe0))
            (ptr-write-u64 (+ codepage offset) 2
                           (nelisp-native-load--symbol-addr (car rest))))
          (setq idx (1+ idx))
          (setq rest (cdr rest))))
      ;; Relocations: each plt32 becomes the displacement to its stub.
      (let ((rest relocs))
        (while rest
          (let* ((reloc (car rest))
                 (offset (plist-get reloc :offset))
                 (symbol (plist-get reloc :symbol))
                 (addend (or (plist-get reloc :addend) 0))
                 (stub (assoc symbol stub-offsets)))
            (unless stub
              (error "nelisp-native-load: relocation for %s has no stub" symbol))
            (unless (<= (+ offset 4) text-length)
              (error "nelisp-native-load: relocation at %d is past %d bytes of text"
                     offset text-length))
            (ptr-write-u32 codepage offset
                           (- (+ codepage (cdr stub) addend)
                              (+ codepage offset))))
          (setq rest (cdr rest))))
      ;; Boundary slots start as nil; the argument slots are filled per call.
      (setq i 0)
      (while (< i (+ 5 nelisp-native-load-callback-slots))
        (nelisp-native-load--zero-slot (+ slots (* 32 i)))
        (setq i (1+ i)))
      ;; ...except scratch, which has to be a vector.  See
      ;; `nelisp-native-load-scratch-slots'.
      (nelisp-native-load--make-scratch-vector (+ slots 32))
      ;; Trampoline: bytes, then the boundary immediates and the entry.
      (nelisp-native-load--poke-bytes trampage 0 tramp-bytes)
      (let ((values (append
                     ;; out, mirror, frames, scratch, name_slot.  Both
                     ;; providers ignore mirror, so it carries the env
                     ;; pointer rather than a wild one.
                     (list slots env env (+ slots 32) (+ slots 64))
                     (let ((cb nil) (k 0))
                       (while (< k nelisp-native-load-callback-slots)
                         (setq cb (cons (+ slots 96 (* 32 k)) cb))
                         (setq k (1+ k)))
                       (nreverse cb))
                     (list (+ codepage body-entry))))
            (offsets (plist-get trampoline :imm64-offsets)))
        (while offsets
          (ptr-write-u64 trampage (car offsets) (car values))
          (setq offsets (cdr offsets))
          (setq values (cdr values))))
      (list :entry trampage
            :codepage codepage
            :stubs stub-offsets
            :body-entry body-entry
            ;; Sizes so `nelisp-native-load-unload' can hand munmap the
            ;; same extents mmap was given.
            :code-size code-size
            :slots-size slots-size
            :entry-size (nelisp-native-load--page-round (length tramp-bytes))
            :slots slots
            :out slots
            :arity arity
            :abi (nelisp-native-load-abi native)
            :return-repr (or (plist-get meta :return-repr) 'unknown)
            :arg-slots (+ slots arg-slot-base)
            :name name
            :path path))))

(defun nelisp-native-load-call (handle args)
  "Call the function in HANDLE with ARGS and return its value.

Which convention is used comes from the handle's :abi, and the two are
not interchangeable -- calling a boxed defun with raw integers makes it
do arithmetic on the values, and calling an integer defun with slot
addresses makes it do arithmetic on the pointers.  Measured on `add3',
an extern-less `(+ a (+ b c))': raw arguments answer 6, boxed arguments
answer 406962619651776 and leave `out' untouched."
  (let ((arity (plist-get handle :arity))
        (arg-slots (plist-get handle :arg-slots))
        (boxed (eq (plist-get handle :abi) 'boxed)))
    (unless (= (length args) arity)
      (error "nelisp-native-load: %s takes %d argument(s), got %d"
             (plist-get handle :name) arity (length args)))
    (let ((i 0)
          (rest args)
          (passed nil)
          (raw nil))
      (while rest
        (if boxed
            (setq passed (cons (nelisp-native-load-box
                                (+ arg-slots (* 32 i)) (car rest))
                               passed))
          (unless (integerp (car rest))
            (error "nelisp-native-load: %s takes integers, got %S"
                   (plist-get handle :name) (car rest)))
          (setq passed (cons (car rest) passed)))
        (setq i (1+ i))
        (setq rest (cdr rest)))
      (setq passed (nreverse passed))
      ;; `ptr-call' reads six arguments after the address unconditionally,
      ;; so hand it six.  Passing fewer leaves it walking off the end of
      ;; the argument list rather than seeing a short call.
      (while (< (length passed) (length nelisp-native-load--arg-regs))
        (setq passed (append passed (list 0))))
      (setq raw (apply (function ptr-call) (plist-get handle :entry) passed))
      ;; The result is what rax holds, not what `out' holds.  For a body
      ;; that ends in a delegated call the two are the same pointer --
      ;; the dispatcher returns `out' -- which is why reading `out'
      ;; looked right until a body ended in something else.  `(let ((v
      ;; (vector 7 8 9))) n)' leaves the vector in `out' and returns the
      ;; boxed `n' in rax, so reading `out' answered with the vector.
      (if (or (eq (plist-get handle :return-repr) 'sexp-ptr)
              (and boxed (eq (plist-get handle :return-repr) 'unknown)))
          (nelisp-native-load-unbox raw)
        raw))))

(defun nelisp-native-load-unload (handle)
  "Unmap HANDLE's pages and return the number of regions released.

A loaded function otherwise stays mapped for the life of the process,
which is what a cache wants but not what a caller loading many artifacts
wants -- the section 9 bench mapped enough of them to be killed.

Calling a handle after unloading it jumps into an unmapped page, so this
blanks the handle's addresses: a stale call then dereferences 0 at the
trampoline rather than executing whatever the kernel maps there next."
  (let ((released 0))
    (dolist (pair (list (cons :entry :entry-size)
                        (cons :codepage :code-size)
                        (cons :slots :slots-size)))
      (let ((addr (plist-get handle (car pair)))
            (size (plist-get handle (cdr pair))))
        (when (and (integerp addr) (> addr 0) (integerp size) (> size 0))
          ;; munmap(2) is syscall 11 on x86_64.
          (let ((rc (syscall-direct 11 addr size 0 0 0 0)))
            (unless (= rc 0)
              (error "nelisp-native-load: munmap of %d bytes at %d failed (%d)"
                     size addr rc))
            (setq released (1+ released))))))
    (plist-put handle :entry 0)
    (plist-put handle :codepage 0)
    (plist-put handle :slots 0)
    (plist-put handle :out 0)
    released))

(defun nelisp-native-load-exec (path name args)
  "Map NAME from PATH and call it with ARGS, in one step."
  (nelisp-native-load-call (nelisp-native-load-artifact path name) args))

(provide 'nelisp-native-load)

;;; nelisp-native-load.el ends here
