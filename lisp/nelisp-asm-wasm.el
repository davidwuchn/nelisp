;;; nelisp-asm-wasm.el --- wasm32 macro assembler primitives  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 164 §2.2 / §6 P0 — minimal wasm encoder for the AOT object path.
;; The buffer discipline mirrors `nelisp-asm-x86_64.el': emit into an
;; opaque grow-only byte buffer, then finalize once.

;;; Code:

(require 'cl-lib)

(define-error 'nelisp-asm-wasm-error
  "nelisp-asm-wasm invariant violated")

(defconst nelisp-asm-wasm--i64 #x7e)
(defconst nelisp-asm-wasm--func #x60)

(defun nelisp-asm-wasm-make-buffer ()
  "Return a fresh wasm byte buffer."
  (vector nil 0))

(defsubst nelisp-asm-wasm--chunks (buf)
  (aref buf 0))

(defsubst nelisp-asm-wasm--length (buf)
  (aref buf 1))

(defun nelisp-asm-wasm-buffer-pos (buf)
  "Return BUF's current byte length."
  (nelisp-asm-wasm--length buf))

(defun nelisp-asm-wasm-buffer-bytes (buf)
  "Finalize BUF into one unibyte string."
  (apply #'concat (nreverse (nelisp-asm-wasm--chunks buf))))

(defun nelisp-asm-wasm--push-bytes (buf bytes)
  "Append BYTES to BUF."
  (aset buf 0 (cons bytes (nelisp-asm-wasm--chunks buf)))
  (aset buf 1 (+ (nelisp-asm-wasm--length buf) (length bytes))))

(defun nelisp-asm-wasm-emit-byte (buf byte)
  "Append BYTE to BUF."
  (nelisp-asm-wasm--push-bytes buf (unibyte-string (logand byte #xff))))

(defun nelisp-asm-wasm-emit-bytes (buf bytes)
  "Append BYTES to BUF."
  (nelisp-asm-wasm--push-bytes buf bytes))

(defun nelisp-asm-wasm-uleb128-bytes (value)
  "Encode VALUE as unsigned LEB128."
  (unless (and (integerp value) (>= value 0))
    (signal 'nelisp-asm-wasm-error (list :uleb128-out-of-range value)))
  (let ((n value)
        (bytes nil)
        (done nil))
    (while (not done)
      (let ((byte (logand n #x7f)))
        (setq n (ash n -7))
        (when (> n 0)
          (setq byte (logior byte #x80)))
        (push byte bytes)
        (setq done (zerop n))))
    (apply #'unibyte-string (nreverse bytes))))

(defun nelisp-asm-wasm-sleb128-bytes (value)
  "Encode VALUE as signed LEB128."
  (unless (integerp value)
    (signal 'nelisp-asm-wasm-error (list :sleb128-not-integer value)))
  (let ((n value)
        (bytes nil)
        done)
    (while (not done)
      (let* ((byte (logand n #x7f))
             (sign-bit (not (zerop (logand byte #x40)))))
        (setq n (ash n -7))
        (setq done (or (and (zerop n) (not sign-bit))
                       (and (= n -1) sign-bit)))
        (unless done
          (setq byte (logior byte #x80)))
        (push byte bytes)))
    (apply #'unibyte-string (nreverse bytes))))

(defun nelisp-asm-wasm-emit-uleb128 (buf value)
  "Append unsigned LEB128 VALUE to BUF."
  (nelisp-asm-wasm-emit-bytes buf (nelisp-asm-wasm-uleb128-bytes value)))

(defun nelisp-asm-wasm-emit-sleb128 (buf value)
  "Append signed LEB128 VALUE to BUF."
  (nelisp-asm-wasm-emit-bytes buf (nelisp-asm-wasm-sleb128-bytes value)))

(defun nelisp-asm-wasm-emit-name (buf name)
  "Append wasm NAME string to BUF."
  (let ((bytes (encode-coding-string name 'utf-8 t)))
    (nelisp-asm-wasm-emit-uleb128 buf (length bytes))
    (nelisp-asm-wasm-emit-bytes buf bytes)))

(defun nelisp-asm-wasm-emit-func-type (buf params results)
  "Append one function type with PARAMS and RESULTS to BUF."
  (nelisp-asm-wasm-emit-byte buf nelisp-asm-wasm--func)
  (nelisp-asm-wasm-emit-uleb128 buf (length params))
  (dolist (param params)
    (nelisp-asm-wasm-emit-byte buf param))
  (nelisp-asm-wasm-emit-uleb128 buf (length results))
  (dolist (result results)
    (nelisp-asm-wasm-emit-byte buf result)))

(defun nelisp-asm-wasm-emit-section (buf id payload)
  "Append section ID with PAYLOAD to BUF."
  (nelisp-asm-wasm-emit-byte buf id)
  (nelisp-asm-wasm-emit-uleb128 buf (length payload))
  (nelisp-asm-wasm-emit-bytes buf payload))

(defun nelisp-asm-wasm-emit-local-decls (buf local-types)
  "Append local declarations for LOCAL-TYPES to BUF."
  (if (null local-types)
      (nelisp-asm-wasm-emit-uleb128 buf 0)
    (let ((groups nil)
          (cur-type nil)
          (cur-count 0))
      (dolist (type local-types)
        (if (eq type cur-type)
            (setq cur-count (1+ cur-count))
          (when cur-type
            (push (cons cur-count cur-type) groups))
          (setq cur-type type
                cur-count 1)))
      (when cur-type
        (push (cons cur-count cur-type) groups))
      (setq groups (nreverse groups))
      (nelisp-asm-wasm-emit-uleb128 buf (length groups))
      (dolist (group groups)
        (nelisp-asm-wasm-emit-uleb128 buf (car group))
        (nelisp-asm-wasm-emit-byte buf (cdr group))))))

(defun nelisp-asm-wasm-make-function-body (local-types expr-bytes)
  "Build one function body from LOCAL-TYPES and EXPR-BYTES."
  (let ((payload (nelisp-asm-wasm-make-buffer))
        (body (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-local-decls payload local-types)
    (nelisp-asm-wasm-emit-bytes payload expr-bytes)
    (let ((payload-bytes (nelisp-asm-wasm-buffer-bytes payload)))
      (nelisp-asm-wasm-emit-uleb128 body (length payload-bytes))
      (nelisp-asm-wasm-emit-bytes body payload-bytes))
    (nelisp-asm-wasm-buffer-bytes body)))

(defun nelisp-asm-wasm-op-i64-const (buf value)
  "Emit `i64.const VALUE'."
  (nelisp-asm-wasm-emit-byte buf #x42)
  (nelisp-asm-wasm-emit-sleb128 buf value))

(defun nelisp-asm-wasm-op-i64-add (buf)
  "Emit `i64.add'."
  (nelisp-asm-wasm-emit-byte buf #x7c))

(defun nelisp-asm-wasm-op-i64-sub (buf)
  "Emit `i64.sub'."
  (nelisp-asm-wasm-emit-byte buf #x7d))

(defun nelisp-asm-wasm-op-i64-mul (buf)
  "Emit `i64.mul'."
  (nelisp-asm-wasm-emit-byte buf #x7e))

(defun nelisp-asm-wasm-op-local-get (buf index)
  "Emit `local.get INDEX'."
  (nelisp-asm-wasm-emit-byte buf #x20)
  (nelisp-asm-wasm-emit-uleb128 buf index))

(defun nelisp-asm-wasm-op-local-set (buf index)
  "Emit `local.set INDEX'."
  (nelisp-asm-wasm-emit-byte buf #x21)
  (nelisp-asm-wasm-emit-uleb128 buf index))

(defun nelisp-asm-wasm-op-call (buf index)
  "Emit `call INDEX'."
  (nelisp-asm-wasm-emit-byte buf #x10)
  (nelisp-asm-wasm-emit-uleb128 buf index))

(defun nelisp-asm-wasm-op-return (buf)
  "Emit `return'."
  (nelisp-asm-wasm-emit-byte buf #x0f))

(defun nelisp-asm-wasm-op-end (buf)
  "Emit `end'."
  (nelisp-asm-wasm-emit-byte buf #x0b))

(provide 'nelisp-asm-wasm)

;;; nelisp-asm-wasm.el ends here
