;;; nelisp-doc200-unibyte-repr-test.el --- Doc 200 unibyte representation gate  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is not part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Phase 1 wrote both Sexp layouts by hand and sent them through the real
;; consumer defuns.  Phase 2 keeps that coverage and additionally executes the
;; production tag-14/tag-15 allocators and tag-15 -> tag-14 finalizer.  The GC
;; mark-buffer shim records the pointer it was asked to mark, making a missing
;; mark arm observable rather than merely checking that `nl_gc_mark_slot'
;; returns.

;;; Code:

(setq load-prefer-newer t)

(require 'ert)
(require 'cl-lib)

(let* ((this (or load-file-name buffer-file-name))
       (test-dir (and this (file-name-directory this)))
       (repo-root (and test-dir
                       (file-name-directory
                        (directory-file-name test-dir)))))
  (dolist (dir '("lisp" "src" "scripts"))
    (let ((path (and repo-root (expand-file-name dir repo-root))))
      (when (and path (file-directory-p path))
        (add-to-list 'load-path path)))))

(require 'nelisp-aot-compiler)
(require 'nelisp-sexp-layout)
(require 'nelisp-standalone-build)
(require 'nelisp-cc-sexp-clone-into)
(require 'nelisp-cc-jit-type-of)
(require 'nelisp-cc-nlstr-direct-ops)

(defconst nelisp-doc200-unibyte-repr-test--page #x30000000
  "Fixed scratch page used only by the freestanding representation probe.")

(defun nelisp-doc200-unibyte-repr-test--forms (source)
  "Return SOURCE's top-level forms, accepting a `(seq ...)' or a list."
  (cond
   ((eq (car-safe source) 'seq) (cdr source))
   ((eq (car-safe source) 'defun) (list source))
   (t source)))

(defun nelisp-doc200-unibyte-repr-test--defun (name source)
  "Return the defun named NAME from SOURCE, or fail the test."
  (or (cl-find-if
       (lambda (form)
         (and (consp form) (eq (car form) 'defun) (eq (cadr form) name)))
       (nelisp-doc200-unibyte-repr-test--forms source))
      (ert-fail (format "Doc 200 probe could not find production defun %S" name))))

(defun nelisp-doc200-unibyte-repr-test--driver-defun (name)
  "Return production driver defun NAME."
  (nelisp-doc200-unibyte-repr-test--defun
   name (nelisp-standalone--reader-driver-source)))

(defun nelisp-doc200-unibyte-repr-test--stub (name args value)
  "Build a test-local defun NAME with ARGS returning VALUE."
  `(defun ,name ,args ,value))

(defun nelisp-doc200-unibyte-repr-test--contains-p (tree needle)
  "Return non-nil when TREE contains a subtree equal to NEEDLE."
  (or (equal tree needle)
      (and (consp tree)
           (or (nelisp-doc200-unibyte-repr-test--contains-p
                (car tree) needle)
               (nelisp-doc200-unibyte-repr-test--contains-p
                (cdr tree) needle)))))

(defun nelisp-doc200-unibyte-repr-test--probe-source ()
  "Return the freestanding AOT source for the tag-14/tag-15 consumer probe."
  (let* ((base nelisp-doc200-unibyte-repr-test--page)
         (slot14 (+ base 32))
         (slot15 (+ base 64))
         (box15 (+ base 96))
         (buf14 (+ base 160))
         (buf15 (+ base 176))
         (dst14 (+ base 208))
         (dst15 (+ base 240))
         (printbuf (+ base 288))
         (producer14 (+ base 352))
         (producer15 (+ base 384))
         (finalized14 (+ base 416))
         (producerbox (+ base 448))
         (producerstrbuf (+ base 480))
         (producerbuf (+ base 512))
         (finalizedbuf (+ base 544))
         (gc-mark-slot
          (nelisp-doc200-unibyte-repr-test--defun
           'nl_gc_mark_slot nelisp-standalone--gc-source))
         (clone-names '(nl_sci_prog2 nl_sci_copy nl_sci_bump
                        nl_sci_rc nl_sci_dispatch))
         (clone-forms
          (mapcar (lambda (name)
                    (nelisp-doc200-unibyte-repr-test--defun
                     name nelisp-cc-sexp-clone-into--source))
                  clone-names))
         (type-dispatch
          (nelisp-doc200-unibyte-repr-test--defun
           'nl_jit_type_of_tag nelisp-cc-jit-type-of--source))
         (arrayp
          (nelisp-doc200-unibyte-repr-test--defun
           'bf_arrayp_raw nelisp-standalone--applyfn-bf-helpers))
         (driver-names '(nl_cli_put_byte nl_cli_put_raw_bytes
                         nl_cli_put_octal_byte
                         nl_cli_put_unibyte_string_value
                         nl_cli_value_to_buf))
         (driver-forms
          (mapcar #'nelisp-doc200-unibyte-repr-test--driver-defun
                  driver-names))
         (strptr
          (nelisp-doc200-unibyte-repr-test--defun
           'nl_bi_strptr nelisp-standalone--fileio-forms-part1))
         (strlen
          (nelisp-doc200-unibyte-repr-test--defun
           'nl_bi_strlen nelisp-standalone--fileio-forms-part1))
         (producer-forms
          (append
           (mapcar
            (lambda (name)
              (nelisp-doc200-unibyte-repr-test--defun
               name nelisp-cc-nlstr-direct-ops--alloc-str-source))
            '(nl_alloc_str_copy_loop nl_alloc_str_write_tag))
           (list
            (nelisp-doc200-unibyte-repr-test--defun
             'nl_alloc_mut_str_write_tag
             nelisp-cc-nlstr-direct-ops--alloc-mut-str-source))
           (mapcar
            (lambda (name)
              (nelisp-doc200-unibyte-repr-test--defun
               name nelisp-cc-nlstr-direct-ops--mut-str-finalize-source))
            '(nl_mut_str_finalize_copy_loop
              nl_mut_str_finalize_unibyte_write))))
         (gc-stubs
          `((defun nl_gc_mark_buf (ptr)
              (seq (ptr-write-u64 ,base 0 ptr) 0))
            (defun nl_gc_mark_block (_ptr) 1)
            (defun nl_gc_mark_cons (_ptr) 0)
            (defun nl_gc_mark_vec_slots (_ptr _i _n) 0)
            (defun nl_gc_mark_char_table_box (_ptr) 0)
            (defun nl_gc_mark_bool_vector_box (_ptr) 0)))
         (clone-stubs
          (cons
           '(defun nelisp_nlstr_clone (box)
              (seq (ptr-write-u64 box 24 (+ (ptr-read-u64 box 24) 1)) box))
           (mapcar
            (lambda (name)
              (nelisp-doc200-unibyte-repr-test--stub name '(box) 'box))
            '(nelisp_nlconsbox_clone nelisp_nlvector_clone
              nelisp_nlchartable_clone nelisp_nlboolvector_clone
              nelisp_nlcell_clone nelisp_nlrecord_clone))))
         (type-stubs
          (append
           (mapcar
            (lambda (name)
              (nelisp-doc200-unibyte-repr-test--stub name '(_out) 0))
            '(nl_jit_to_write_cons nl_jit_to_write_symbol
              nl_jit_to_write_integer nl_jit_to_write_float
              nl_jit_to_write_vector nl_jit_to_write_char_table
              nl_jit_to_write_bool_vector))
           '((defun nl_jit_to_write_string (_out) 77))))
         (printer-stubs
          '((defun nl_cli_put_nil (_buf off) off)
            (defun nl_cli_put_dec (_buf off _v) off)
            (defun nl_cli_put_string_value (_buf off _sx _quoted) off)
            (defun nl_cli_put_list_tail (_buf off _node _first) off)
            (defun nl_cli_put_vector_loop (_buf off _vec _i _n) off)
            (defun nl_cli_put_object (_buf off) off)))
         (other-stubs
          '((defun nl_alloc_str (_src _len dst) dst)
            (defun nl_alloc_symbol (_src _len dst) dst)))
         (probe-defs
          `((defun doc200_stringp (p)
              ;; This call is intentionally compiled through the production
              ;; AOT direct-tag lowering, not duplicated as numeric tests here.
              (if (stringp p) 1 0))
            (defun doc200_sequencep (p)
              ;; This is the production `nelisp-stdlib.el' composition.
              (if (or (null p) (consp p) (stringp p) (vectorp p)) 1 0))
            (defun doc200_predicate_probe ()
              (+
               (if (= (doc200_stringp ,slot14) 1) 0 1)
               (if (= (doc200_stringp ,slot15) 1) 0 2)
               (if (= (bf_arrayp_raw ,slot14) 1) 0 4)
               (if (= (bf_arrayp_raw ,slot15) 1) 0 8)
               (if (= (doc200_sequencep ,slot14) 1) 0 16)
               (if (= (doc200_sequencep ,slot15) 1) 0 32)
               (if (= (nl_jit_type_of_tag 14 0) 77) 0 64)
               (if (= (nl_jit_type_of_tag 15 0) 77) 0 128)))
            (defun doc200_gc_probe ()
              (seq
               (ptr-write-u64 ,base 0 0)
               (nl_gc_mark_slot ,slot14)
               (if (= (ptr-read-u64 ,base 0) ,buf14)
                   (seq
                    (ptr-write-u64 ,base 0 0)
                    (nl_gc_mark_slot ,slot15)
                    (if (= (ptr-read-u64 ,base 0) ,buf15) 0 2))
                 1)))
            (defun doc200_clone_probe ()
              (seq
               (nl_sci_dispatch ,slot14 ,dst14 14)
               (nl_sci_dispatch ,slot15 ,dst15 15)
               (+
                (if (= (ptr-read-u8 ,dst14 0) 14) 0 1)
                (if (= (ptr-read-u64 ,dst14 16) ,buf14) 0 2)
                (if (= (ptr-read-u64 ,dst14 24) 3) 0 4)
                (if (= (ptr-read-u8 (ptr-read-u64 ,dst14 16) 1) 200) 0 8)
                (if (= (ptr-read-u8 ,dst15 0) 15) 0 16)
                (if (= (ptr-read-u64 ,dst15 8) ,box15) 0 32)
                (if (= (ptr-read-u64 (ptr-read-u64 ,dst15 8) 16) 3) 0 64)
                (if (= (ptr-read-u8
                        (ptr-read-u64 (ptr-read-u64 ,dst15 8) 8) 1)
                       201)
                    0 128)
                (if (= (ptr-read-u64 ,box15 24) 2) 0 1))))
            (defun doc200_print_probe ()
              (seq
               (nl_cli_value_to_buf ,printbuf 0 ,slot14)
               (nl_cli_value_to_buf (+ ,printbuf 32) 0 ,slot15)
               (+
                (if (= (ptr-read-u8 ,printbuf 0) 34) 0 1)
                (if (= (ptr-read-u8 ,printbuf 1) 65) 0 2)
                (if (= (ptr-read-u8 ,printbuf 2) 92) 0 4)
                (if (= (ptr-read-u8 ,printbuf 3) 51) 0 8)
                (if (= (ptr-read-u8 ,printbuf 4) 49) 0 16)
                (if (= (ptr-read-u8 ,printbuf 5) 48) 0 32)
                (if (= (ptr-read-u8 ,printbuf 6) 66) 0 64)
                (if (= (ptr-read-u8 ,printbuf 7) 34) 0 128)
                (if (= (ptr-read-u8 (+ ,printbuf 32) 2) 92) 0 1)
                (if (= (ptr-read-u8 (+ ,printbuf 32) 3) 51) 0 2)
                (if (= (ptr-read-u8 (+ ,printbuf 32) 4) 49) 0 4)
                (if (= (ptr-read-u8 (+ ,printbuf 32) 5) 49) 0 8))))
            (defun doc200_producer_probe ()
              (seq
               ;; Immutable raw-byte allocation must write tag 14 and retain
               ;; the byte payload without UTF-8 interpretation.
               (nl_alloc_str_write_tag
                ,buf14 3 3 ,producer14 ,producerstrbuf 14)
               ;; Mutable raw-byte allocation must write tag 15.  Populate
               ;; its fresh NlStr buffer, then exercise the production
               ;; finalizer and require a tag-14 immutable result.
               (nl_alloc_mut_str_write_tag
                3 ,producer15 ,producerbox ,producerbuf 15)
               (ptr-write-u8 ,producerbuf 0 200)
               (ptr-write-u8 ,producerbuf 1 201)
               (ptr-write-u8 ,producerbuf 2 202)
               (ptr-write-u64 ,producerbox 16 3)
               (nl_mut_str_finalize_unibyte_write
                ,producerbuf 3 3 ,finalized14 ,finalizedbuf)
               (+
                (if (= (ptr-read-u8 ,producer14 0) 14) 0 1)
                (if (= (ptr-read-u64 ,producer14 24) 3) 0 2)
                (if (= (ptr-read-u8 (ptr-read-u64 ,producer14 16) 1) 200)
                    0 4)
                (if (= (ptr-read-u8 ,producer15 0) 15) 0 8)
                (if (= (ptr-read-u8 ,finalized14 0) 14) 0 16)
                (if (= (ptr-read-u64 ,finalized14 24) 3) 0 32)
                (if (= (ptr-read-u8 (ptr-read-u64 ,finalized14 16) 2) 202)
                    0 64))))
            (defun doc200_setup ()
              (seq
               ;; mmap(BASE, 4096, PROT_RW, MAP_FIXED|PRIVATE|ANON, -1, 0)
               (syscall-direct 9 ,base 4096 3 50 -1 0)
               ;; UnibyteStr: tag@0, cap@8, ptr@16, byte-len@24.
               (ptr-write-u64 ,slot14 0 14)
               (ptr-write-u64 ,slot14 8 3)
               (ptr-write-u64 ,slot14 16 ,buf14)
               (ptr-write-u64 ,slot14 24 3)
               (ptr-write-u8 ,buf14 0 65)
               (ptr-write-u8 ,buf14 1 200)
               (ptr-write-u8 ,buf14 2 66)
               ;; UnibyteMutStr: tag@0, NlStr*@8; box cap/ptr/len/rc.
               (ptr-write-u64 ,slot15 0 15)
               (ptr-write-u64 ,slot15 8 ,box15)
               (ptr-write-u64 ,box15 0 3)
               (ptr-write-u64 ,box15 8 ,buf15)
               (ptr-write-u64 ,box15 16 3)
               (ptr-write-u64 ,box15 24 1)
               (ptr-write-u8 ,buf15 0 65)
               (ptr-write-u8 ,buf15 1 201)
               (ptr-write-u8 ,buf15 2 66)
               0))
            (defun doc200_probe ()
              (seq
               (doc200_setup)
               (+ (doc200_predicate_probe)
                  (doc200_gc_probe)
                  (doc200_clone_probe)
                  (doc200_print_probe)
                  (doc200_producer_probe)))))))
    `(seq
      ,@gc-stubs
      ,@clone-stubs
      ,@type-stubs
      ,@printer-stubs
      ,@other-stubs
      ,gc-mark-slot
      ,@clone-forms
      ,type-dispatch
      ,arrayp
      ,strptr
      ,strlen
      ,@producer-forms
      ,@driver-forms
      ,@probe-defs
      (exit (doc200_probe)))))

(ert-deftest nelisp-doc200-unibyte-repr/production-and-consumers-use-unibyte-tags ()
  "Production alloc/finalize and hand-built tags survive every representation path."
  (unless (and (eq system-type 'gnu/linux)
               (string-match-p "x86_64\\|amd64" system-configuration))
    (ert-skip "Requires x86_64 Linux for the freestanding AOT executable"))
  (let ((path (make-temp-file "nelisp-doc200-unibyte-repr-")))
    (unwind-protect
        (progn
          (nelisp-aot-compile-sexp
           (nelisp-doc200-unibyte-repr-test--probe-source) path)
          (should (file-executable-p path))
          (let ((rc (call-process path nil nil nil)))
            (should (= rc 0))))
      (when (file-exists-p path)
        (delete-file path)))))

(ert-deftest nelisp-doc200-unibyte-repr/aot-stringp-expansion-has-all-four-tags ()
  "The direct AOT stringp expansion admits both string representations."
  (should
   (equal
    (nelisp-aot-compiler--aot-direct-tag-predicate-form '(stringp arg))
    '(or (= (sexp-tag arg) 5)
         (= (sexp-tag arg) 6)
         (= (sexp-tag arg) 14)
         (= (sexp-tag arg) 15)))))

(ert-deftest nelisp-doc200-unibyte-repr/public-producers-select-unibyte-tags ()
  "Public raw-string alloc/finalize wrappers select tags 14 and 15."
  (let ((str
         (nelisp-doc200-unibyte-repr-test--defun
          'nl_alloc_unibyte_str_pos
          nelisp-cc-nlstr-direct-ops--alloc-str-source))
        (mut
         (nelisp-doc200-unibyte-repr-test--defun
          'nl_alloc_unibyte_mut_str_inner
          nelisp-cc-nlstr-direct-ops--alloc-mut-str-source))
        (finalize
         (nelisp-doc200-unibyte-repr-test--defun
          'nl_mut_str_finalize
          nelisp-cc-nlstr-direct-ops--mut-str-finalize-source)))
    (should
     (nelisp-doc200-unibyte-repr-test--contains-p
      str '(alloc-bytes (if (= n 0) 1 n) 1)))
    (should (nelisp-doc200-unibyte-repr-test--contains-p str 14))
    (should (nelisp-doc200-unibyte-repr-test--contains-p mut 15))
    (should
     (nelisp-doc200-unibyte-repr-test--contains-p
      finalize '(if (= (ptr-read-u8 ptr 0) 15) 14 5)))))

(provide 'nelisp-doc200-unibyte-repr-test)
;;; nelisp-doc200-unibyte-repr-test.el ends here
