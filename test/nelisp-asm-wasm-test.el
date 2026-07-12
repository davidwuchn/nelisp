;;; nelisp-asm-wasm-test.el --- tests for wasm encoder/writer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;;; Code:

(require 'ert)
(require 'nelisp-asm-wasm)
(require 'nelisp-wasm-write)

(defun nelisp-asm-wasm-test--decode-uleb128 (bytes)
  "Decode unsigned LEB128 BYTES."
  (let ((result 0)
        (shift 0)
        (i 0)
        done)
    (while (not done)
      (let ((byte (aref bytes i)))
        (setq result (logior result (ash (logand byte #x7f) shift))
              shift (+ shift 7)
              i (1+ i)
              done (zerop (logand byte #x80)))))
    result))

(defun nelisp-asm-wasm-test--decode-sleb128 (bytes)
  "Decode signed LEB128 BYTES."
  (let ((result 0)
        (shift 0)
        (size 64)
        (i 0)
        byte)
    (while (progn
             (setq byte (aref bytes i))
             (setq result (logior result (ash (logand byte #x7f) shift))
                   shift (+ shift 7)
                   i (1+ i))
             (not (zerop (logand byte #x80))))
      nil)
    (when (and (< shift size) (not (zerop (logand byte #x40))))
      (setq result (logior result (ash -1 shift))))
    result))

(ert-deftest nelisp-asm-wasm/uleb128-round-trip ()
  (dolist (value '(0 63 64 127 128 16383 16384 2147483647))
    (should
     (= value
        (nelisp-asm-wasm-test--decode-uleb128
         (nelisp-asm-wasm-uleb128-bytes value))))))

(ert-deftest nelisp-asm-wasm/sleb128-round-trip ()
  (dolist (value '(0 -1 1 63 64 127 128 -64 -65 -127 -128 -129))
    (should
     (= value
        (nelisp-asm-wasm-test--decode-sleb128
         (nelisp-asm-wasm-sleb128-bytes value))))))

(ert-deftest nelisp-asm-wasm/op-call-indirect-encodes ()
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-op-call-indirect buf 3 0)
    (should (equal (nelisp-asm-wasm-buffer-bytes buf)
                   (unibyte-string #x11 #x03 #x00)))))

(ert-deftest nelisp-asm-wasm/op-structured-control-encodes ()
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-op-block buf)
    (nelisp-asm-wasm-op-loop buf)
    (nelisp-asm-wasm-op-br-if buf 1)
    (nelisp-asm-wasm-op-br buf 0)
    (nelisp-asm-wasm-op-else buf)
    (nelisp-asm-wasm-op-end buf)
    (should (equal (nelisp-asm-wasm-buffer-bytes buf)
                   (unibyte-string
                    #x02 #x40 #x03 #x40 #x0d #x01 #x0c #x00 #x05 #x0b)))))

(ert-deftest nelisp-asm-wasm/op-memory-wrap-and-load-encodes ()
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-op-i32-wrap-i64 buf)
    (nelisp-asm-wasm-op-i64-load32-u buf)
    (nelisp-asm-wasm-op-i64-extend-i32-u buf)
    (should (equal (nelisp-asm-wasm-buffer-bytes buf)
                   (unibyte-string #xa7 #x35 #x02 #x00 #xad)))))

(ert-deftest nelisp-asm-wasm/op-f64-sqrt-bits-round-trip-encodes ()
  (let ((buf (nelisp-asm-wasm-make-buffer)))
    (nelisp-asm-wasm-op-f64-reinterpret-i64 buf)
    (nelisp-asm-wasm-op-f64-sqrt buf)
    (nelisp-asm-wasm-op-i64-reinterpret-f64 buf)
    (should (equal (nelisp-asm-wasm-buffer-bytes buf)
                   (unibyte-string #xbf #x9f #xbd)))))

(ert-deftest nelisp-asm-wasm/writer-emits-table-and-element-sections ()
  (let ((path (make-temp-file "nelisp-wasm-" nil ".wasm")))
    (unwind-protect
        (progn
          (nelisp-wasm-write-binary
           path
           (list :wasm-types (list (list :params nil :results (list #x7e)))
                 :wasm-table-size 1
                 :wasm-element-indices '(0)
                 :wasm-functions
                 (list (list :name "f"
                             :type-index 0
                             :body (nelisp-asm-wasm-make-function-body
                                    nil
                                    (unibyte-string #x42 #x00 #x0f #x0b))))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally path)
            (goto-char 1)
            (should (search-forward (string #x04) nil t))
            (goto-char 1)
            (should (search-forward (string #x09) nil t))))
      (when (file-exists-p path)
        (delete-file path)))))

(provide 'nelisp-asm-wasm-test)

;;; nelisp-asm-wasm-test.el ends here
