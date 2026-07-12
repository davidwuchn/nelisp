;;; nelisp-asm-wasm-test.el --- tests for wasm encoder/writer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;;; Code:

(require 'ert)
(require 'nelisp-asm-wasm)
(require 'nelisp-aot-compiler)

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

(ert-deftest nelisp-asm-wasm/compile-minimal-module ()
  (let ((path (make-temp-file "nelisp-wasm-" nil ".wasm")))
    (unwind-protect
        (progn
          (nelisp-aot-compile-to-object
           '(defun f () (+ (* 6 7) 0))
           path
           :arch 'wasm32
           :format 'wasm)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally path)
            (should (equal (buffer-substring-no-properties 1 9)
                           (unibyte-string #x00 #x61 #x73 #x6d
                                           #x01 #x00 #x00 #x00))))))
      (when (file-exists-p path)
        (delete-file path))))

(provide 'nelisp-asm-wasm-test)

;;; nelisp-asm-wasm-test.el ends here
