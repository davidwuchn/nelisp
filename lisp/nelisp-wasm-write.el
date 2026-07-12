;;; nelisp-wasm-write.el --- wasm32 module writer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 164 §2.2 / §6 P0 — binary writer for minimal self-contained wasm
;; modules produced by the AOT compiler.

;;; Code:

(require 'cl-lib)
(require 'nelisp-asm-wasm)

(defconst nelisp-wasm-write--magic
  (unibyte-string #x00 #x61 #x73 #x6d #x01 #x00 #x00 #x00))

(defun nelisp-wasm-write--payload-types (types)
  "Build the Type section payload for TYPES."
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-uleb128 buf (length types))
    (dolist (type types)
      (nelisp-asm-wasm-emit-func-type
       buf
       (plist-get type :params)
       (plist-get type :results)))
    (nelisp-asm-wasm-buffer-bytes buf)))

(defun nelisp-wasm-write--payload-functions (functions)
  "Build the Function section payload for FUNCTIONS."
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-uleb128 buf (length functions))
    (dolist (fn functions)
      (nelisp-asm-wasm-emit-uleb128 buf (plist-get fn :type-index)))
    (nelisp-asm-wasm-buffer-bytes buf)))

(defun nelisp-wasm-write--payload-memory ()
  "Build the wasm Memory section payload."
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-uleb128 buf 1)
    (nelisp-asm-wasm-emit-byte buf 0)
    (nelisp-asm-wasm-emit-uleb128 buf 1)
    (nelisp-asm-wasm-buffer-bytes buf)))

(defun nelisp-wasm-write--payload-table (unit)
  "Build the Table section payload for UNIT."
  (let ((table-size (or (plist-get unit :wasm-table-size) 0)))
    (when (> table-size 0)
      (let ((buf (nelisp-asm-wasm-make-buffer)))
        (nelisp-asm-wasm-emit-uleb128 buf 1)
        (nelisp-asm-wasm-emit-byte buf nelisp-asm-wasm--funcref)
        (nelisp-asm-wasm-emit-byte buf 0)
        (nelisp-asm-wasm-emit-uleb128 buf table-size)
        (nelisp-asm-wasm-buffer-bytes buf)))))

(defun nelisp-wasm-write--emit-const-i32-expr (buf value)
  "Append an `i32.const VALUE; end' init expr to BUF."
  (nelisp-asm-wasm-emit-byte buf #x41)
  (nelisp-asm-wasm-emit-sleb128 buf value)
  (nelisp-asm-wasm-op-end buf))

(defun nelisp-wasm-write--payload-element (unit)
  "Build the Element section payload for UNIT."
  (let ((elems (plist-get unit :wasm-element-indices)))
    (when elems
      (let ((buf (nelisp-asm-wasm-make-buffer)))
        (nelisp-asm-wasm-emit-uleb128 buf 1)
        (nelisp-asm-wasm-emit-byte buf 0)
        (nelisp-wasm-write--emit-const-i32-expr buf 0)
        (nelisp-asm-wasm-emit-uleb128 buf (length elems))
        (dolist (index elems)
          (nelisp-asm-wasm-emit-uleb128 buf index))
        (nelisp-asm-wasm-buffer-bytes buf)))))

(defun nelisp-wasm-write--payload-exports (functions)
  "Build the Export section payload for FUNCTIONS."
  (let ((buf (nelisp-asm-wasm-make-buffer))
        (index 0))
    (nelisp-asm-wasm-emit-uleb128 buf (length functions))
    (dolist (fn functions)
      (nelisp-asm-wasm-emit-name buf (plist-get fn :name))
      (nelisp-asm-wasm-emit-byte buf 0)
      (nelisp-asm-wasm-emit-uleb128 buf index)
      (setq index (1+ index)))
    (nelisp-asm-wasm-buffer-bytes buf)))

(defun nelisp-wasm-write--payload-code (functions)
  "Build the Code section payload for FUNCTIONS."
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-uleb128 buf (length functions))
    (dolist (fn functions)
      (nelisp-asm-wasm-emit-bytes buf (plist-get fn :body)))
    (nelisp-asm-wasm-buffer-bytes buf)))

(defun nelisp-wasm-write-binary (file-path unit)
  "Write wasm UNIT to FILE-PATH and return FILE-PATH."
  (let* ((types (plist-get unit :wasm-types))
         (functions (plist-get unit :wasm-functions))
         (table (nelisp-wasm-write--payload-table unit))
         (element (nelisp-wasm-write--payload-element unit))
         (buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-emit-bytes buf nelisp-wasm-write--magic)
    (nelisp-asm-wasm-emit-section
     buf 1 (nelisp-wasm-write--payload-types types))
    (nelisp-asm-wasm-emit-section
     buf 3 (nelisp-wasm-write--payload-functions functions))
    (when table
      (nelisp-asm-wasm-emit-section buf 4 table))
    (nelisp-asm-wasm-emit-section
     buf 5 (nelisp-wasm-write--payload-memory))
    (nelisp-asm-wasm-emit-section
     buf 7 (nelisp-wasm-write--payload-exports functions))
    (when element
      (nelisp-asm-wasm-emit-section buf 9 element))
    (nelisp-asm-wasm-emit-section
     buf 10 (nelisp-wasm-write--payload-code functions))
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file file-path
        (set-buffer-multibyte nil)
        (insert (nelisp-asm-wasm-buffer-bytes buf))))
    file-path))

(provide 'nelisp-wasm-write)

;;; nelisp-wasm-write.el ends here
