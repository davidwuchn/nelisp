;;; nl-safe-test.el --- ERT tests for nl-safe -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Coverage for `src/nl-safe.el' (Doc 170 Stage 1): borrow cells and
;; the aliasing-XOR-mutation rule, fat pointer bounds / generation
;; checking, the `nl-unsafe' boundary with the strict gate, the
;; violation log, and the expansion-identity gate for the disable
;; flag (Doc 170 section 9).
;;
;; This file deliberately avoids cl-lib and ert-x helpers so the same
;; test bodies can run on `target/nelisp' standalone through the mini
;; harness in `test/nl-safe-standalone-smoke.el'.

;;; Code:

(require 'ert)
(require 'nl-safe)

;;; Cell representation ------------------------------------------------

(ert-deftest nl-safe-cell-p-basics ()
  (should (nl-cell-p (nl-cell 1)))
  (should (nl-cell-p (nl-cell nil)))
  (should-not (nl-cell-p nil))
  (should-not (nl-cell-p 42))
  (should-not (nl-cell-p (vector 'other 1 0)))
  (should-not (nl-cell-p (vector 'nl--cell 1))))

(ert-deftest nl-safe-cell-initial-state ()
  (let ((c (nl-cell 'v)))
    (should (eq (aref c 0) 'nl--cell))
    (should (eq (aref c 1) 'v))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-defcell-defines-variable ()
  (eval '(nl-defcell nl-safe-test--gcell (make-vector 4 7)))
  (should (boundp 'nl-safe-test--gcell))
  (should (nl-cell-p (symbol-value 'nl-safe-test--gcell)))
  (should (= (aref (aref (symbol-value 'nl-safe-test--gcell) 1) 0) 7)))

(ert-deftest nl-safe-defcell-rejects-non-symbol ()
  (should-error (macroexpand '(nl-defcell (a b) 1))))

;;; Shared borrow -------------------------------------------------------

(ert-deftest nl-safe-borrow-binds-value ()
  (let ((c (nl-cell (vector 10 20))))
    (should (= (nl-with-borrow (b c) (aref b 1)) 20))))

(ert-deftest nl-safe-borrow-returns-body-value ()
  (let ((c (nl-cell 1)))
    (should (eq (nl-with-borrow (_b c) 'done) 'done))))

(ert-deftest nl-safe-borrow-state-during-and-after ()
  (let ((c (nl-cell 1)))
    (nl-with-borrow (_b c)
      (should (= (aref c 2) 1)))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-shared-nesting-allowed ()
  (let ((c (nl-cell 5)))
    (should (= (nl-with-borrow (a c)
                 (nl-with-borrow (b c)
                   (should (= (aref c 2) 2))
                   (+ a b)))
               10))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-three-shared ()
  (let ((c (nl-cell 1)))
    (nl-with-borrow (_a c)
      (nl-with-borrow (_b c)
        (nl-with-borrow (_d c)
          (should (= (aref c 2) 3)))))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-sequential-reuse ()
  (let ((c (nl-cell 3)))
    (should (= (nl-with-borrow (b c) b) 3))
    (should (= (nl-with-borrow (b c) b) 3))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-non-cell-type-error ()
  (should-error (nl-with-borrow (_b 42) nil) :type 'nl-type-error)
  (should-error (nl-with-borrow (_b nil) nil) :type 'nl-type-error))

(ert-deftest nl-safe-borrow-bad-spec-expansion-error ()
  (should-error (macroexpand '(nl-with-borrow b nil)))
  (should-error (macroexpand '(nl-with-borrow (b) nil)))
  (should-error (macroexpand '(nl-with-borrow (b c d) nil))))

;;; Exclusive borrow ----------------------------------------------------

(ert-deftest nl-safe-borrow-mut-binds-and-mutates ()
  (let ((c (nl-cell (make-vector 3 0))))
    (nl-with-borrow-mut (b c)
      (aset b 0 42))
    (should (= (nl-with-borrow (b c) (aref b 0)) 42))))

(ert-deftest nl-safe-borrow-mut-returns-body-value ()
  (let ((c (nl-cell 1)))
    (should (eq (nl-with-borrow-mut (_b c) 'done) 'done))))

(ert-deftest nl-safe-borrow-mut-state-during-and-after ()
  (let ((c (nl-cell 1)))
    (nl-with-borrow-mut (_b c)
      (should (= (aref c 2) -1)))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-mut-sequential-reuse ()
  (let ((c (nl-cell 3)))
    (should (= (nl-with-borrow-mut (b c) b) 3))
    (should (= (nl-with-borrow-mut (b c) b) 3))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-mut-non-cell-type-error ()
  (should-error (nl-with-borrow-mut (_b "cell") nil) :type 'nl-type-error))

(ert-deftest nl-safe-borrow-mut-bad-spec-expansion-error ()
  (should-error (macroexpand '(nl-with-borrow-mut b nil)))
  (should-error (macroexpand '(nl-with-borrow-mut (b c d) nil))))

;;; Aliasing XOR mutation violations ------------------------------------

(ert-deftest nl-safe-mut-inside-shared-signals ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil))
                  :type 'nl-borrow-error)))

(ert-deftest nl-safe-shared-inside-mut-signals ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow-mut (_a c)
                    (nl-with-borrow (_b c) nil))
                  :type 'nl-borrow-error)))

(ert-deftest nl-safe-mut-inside-mut-signals ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow-mut (_a c)
                    (nl-with-borrow-mut (_b c) nil))
                  :type 'nl-borrow-error)))

(ert-deftest nl-safe-violation-error-data ()
  (let* ((c (nl-cell 1))
         (err (should-error (nl-with-borrow-mut (_a c)
                              (nl-with-borrow (_b c) nil))
                            :type 'nl-borrow-error)))
    (should (eq (plist-get (cdr err) :existing) 'exclusive))
    (should (eq (plist-get (cdr err) :requested) 'shared))
    (should (eq (plist-get (cdr err) :cell) 'c))))

(ert-deftest nl-safe-failed-borrow-leaks-no-state ()
  (let ((c (nl-cell 1)))
    (nl-with-borrow (_a c)
      (condition-case nil
          (nl-with-borrow-mut (_b c) nil)
        (nl-borrow-error nil))
      ;; Still exactly one shared borrow: the failed acquire must not
      ;; have moved the state.
      (should (= (aref c 2) 1)))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-different-cells-independent ()
  (let ((c1 (nl-cell 1))
        (c2 (nl-cell 2)))
    (should (= (nl-with-borrow-mut (a c1)
                 (nl-with-borrow-mut (b c2) (+ a b)))
               3))))

;;; Borrow state restore on non-local exit -------------------------------

(ert-deftest nl-safe-borrow-restored-after-signal ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow (_b c) (error "boom")))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-mut-restored-after-signal ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow-mut (_b c) (error "boom")))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-restored-after-throw ()
  (let ((c (nl-cell 1)))
    (should (eq (catch 'out
                  (nl-with-borrow (_b c) (throw 'out 'left)))
                'left))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-borrow-mut-restored-after-throw ()
  (let ((c (nl-cell 1)))
    (should (eq (catch 'out
                  (nl-with-borrow-mut (_b c) (throw 'out 'left)))
                'left))
    (should (= (aref c 2) 0))))

(ert-deftest nl-safe-nested-borrow-restored-after-inner-signal ()
  (let ((c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow (_b c)
                      (error "boom"))))
    (should (= (aref c 2) 0))))

;;; Violation log --------------------------------------------------------

(ert-deftest nl-safe-no-log-when-disabled ()
  (let ((nl-safe-log-violations nil)
        (nl-safe--violation-log nil)
        (c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should (null nl-safe--violation-log))))

(ert-deftest nl-safe-borrow-violation-logged ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should (= (length nl-safe--violation-log) 1))
    (let ((rec (car nl-safe--violation-log)))
      (should (eq (plist-get rec :kind) 'borrow))
      (should (eq (plist-get rec :cell) 'c))
      (should (eq (plist-get rec :existing) 'shared))
      (should (= (plist-get rec :existing-shared-count) 1))
      (should (eq (plist-get rec :requested) 'exclusive)))))

(ert-deftest nl-safe-borrow-violation-logged-exclusive-existing ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (c (nl-cell 1)))
    (should-error (nl-with-borrow-mut (_a c)
                    (nl-with-borrow (_b c) nil)))
    (let ((rec (car nl-safe--violation-log)))
      (should (eq (plist-get rec :existing) 'exclusive))
      (should (= (plist-get rec :existing-shared-count) 0))
      (should (eq (plist-get rec :requested) 'shared)))))

(ert-deftest nl-safe-violation-log-accumulates ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should-error (nl-with-borrow-mut (_a c)
                    (nl-with-borrow-mut (_b c) nil)))
    (should (= (length nl-safe--violation-log) 2))
    ;; Newest first.
    (should (eq (plist-get (car nl-safe--violation-log) :requested)
                'exclusive))
    (should (eq (plist-get (car nl-safe--violation-log) :existing)
                'exclusive))))

(ert-deftest nl-safe-shared-count-in-log ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (c (nl-cell 1)))
    (should-error (nl-with-borrow (_a c)
                    (nl-with-borrow (_b c)
                      (nl-with-borrow-mut (_d c) nil))))
    (should (= (plist-get (car nl-safe--violation-log)
                          :existing-shared-count)
               2))))

;;; Error hierarchy ------------------------------------------------------

(ert-deftest nl-safe-borrow-error-hierarchy ()
  (let ((conds (get 'nl-borrow-error 'error-conditions)))
    (should (memq 'nl-borrow-error conds))
    (should (memq 'nl-error conds))
    (should (memq 'error conds))))

(ert-deftest nl-safe-ptr-error-hierarchy ()
  (let ((bounds (get 'nl-ptr-bounds-error 'error-conditions))
        (gen (get 'nl-ptr-generation-error 'error-conditions)))
    (should (memq 'nl-ptr-error bounds))
    (should (memq 'nl-error bounds))
    (should (memq 'nl-ptr-error gen))
    (should (memq 'nl-error gen))))

(ert-deftest nl-safe-borrow-error-caught-by-condition-case ()
  ;; Catch by the precise symbol: standalone NeLisp's `condition-case'
  ;; does not dispatch on derived conditions (an `nl-error' handler
  ;; would not catch `nl-borrow-error' there), so hierarchy membership
  ;; is asserted through `error-conditions' in the tests above instead.
  (let ((c (nl-cell 1)))
    (should (eq (condition-case nil
                    (nl-with-borrow-mut (_a c)
                      (nl-with-borrow-mut (_b c) nil))
                  (nl-borrow-error 'caught))
                'caught))))

;;; Fat pointer basics ---------------------------------------------------

(ert-deftest nl-safe-ptr-make-and-predicates ()
  (let ((p (nl-ptr-make (nl-safe-mock-alloc 8) 8 0)))
    (should (nl-ptr-p p))
    (should (= (nl-ptr-len p) 8))
    (should-not (nl-ptr-p (vector 'nl--ptr 1 2)))
    (should-not (nl-ptr-p 42))
    (should-not (nl-ptr-p nil))))

(ert-deftest nl-safe-ptr-len-type-error ()
  (should-error (nl-ptr-len 42) :type 'nl-type-error))

(ert-deftest nl-safe-mock-ptr-convenience ()
  (let ((p (nl-safe-mock-ptr 16)))
    (should (nl-ptr-p p))
    (should (= (nl-ptr-len p) 16))
    (should (= (nl-ptr-ref-u8 p 0) 0))))

(ert-deftest nl-safe-ptr-u8-roundtrip ()
  (let ((p (nl-safe-mock-ptr 4)))
    (nl-ptr-set-u8 p 2 99)
    (should (= (nl-ptr-ref-u8 p 2) 99))
    (should (= (nl-ptr-ref-u8 p 0) 0))))

(ert-deftest nl-safe-ptr-u8-boundary-ok ()
  (let ((p (nl-safe-mock-ptr 4)))
    (nl-ptr-set-u8 p 3 255)
    (should (= (nl-ptr-ref-u8 p 3) 255))))

(ert-deftest nl-safe-ptr-u64-little-endian ()
  (let ((p (nl-safe-mock-ptr 8)))
    (nl-ptr-set-u8 p 0 #x78)
    (nl-ptr-set-u8 p 1 #x56)
    (nl-ptr-set-u8 p 2 #x34)
    (nl-ptr-set-u8 p 3 #x12)
    (should (= (nl-ptr-ref-u64 p 0) #x12345678))))

(ert-deftest nl-safe-ptr-u64-high-byte ()
  (let ((p (nl-safe-mock-ptr 8)))
    (nl-ptr-set-u8 p 7 1)
    (should (= (nl-ptr-ref-u64 p 0) (expt 2 56)))))

(ert-deftest nl-safe-ptr-u64-offset ()
  (let ((p (nl-safe-mock-ptr 16)))
    (nl-ptr-set-u8 p 8 5)
    (should (= (nl-ptr-ref-u64 p 8) 5))))

;;; Fat pointer bounds checking ------------------------------------------

(ert-deftest nl-safe-ptr-ref-u8-out-of-bounds ()
  (let ((p (nl-safe-mock-ptr 4)))
    (should-error (nl-ptr-ref-u8 p 4) :type 'nl-ptr-bounds-error)
    (should-error (nl-ptr-ref-u8 p 100) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-ref-u8-negative-offset ()
  (let ((p (nl-safe-mock-ptr 4)))
    (should-error (nl-ptr-ref-u8 p -1) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-set-u8-out-of-bounds ()
  (let ((p (nl-safe-mock-ptr 4)))
    (should-error (nl-ptr-set-u8 p 4 0) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-set-u8-bad-value ()
  (let ((p (nl-safe-mock-ptr 4)))
    (should-error (nl-ptr-set-u8 p 0 256) :type 'nl-type-error)
    (should-error (nl-ptr-set-u8 p 0 -1) :type 'nl-type-error)
    (should-error (nl-ptr-set-u8 p 0 'x) :type 'nl-type-error)))

(ert-deftest nl-safe-ptr-u64-bounds ()
  (let ((p (nl-safe-mock-ptr 16)))
    (should (= (nl-ptr-ref-u64 p 8) 0))
    (should-error (nl-ptr-ref-u64 p 9) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-accessor-type-error ()
  (should-error (nl-ptr-ref-u8 42 0) :type 'nl-type-error)
  (should-error (nl-ptr-set-u8 nil 0 0) :type 'nl-type-error)
  (should-error (nl-ptr-ref-u64 "p" 0) :type 'nl-type-error))

(ert-deftest nl-safe-ptr-bounds-error-data ()
  (let* ((p (nl-safe-mock-ptr 4))
         (err (should-error (nl-ptr-ref-u64 p 1)
                            :type 'nl-ptr-bounds-error)))
    (should (eq (plist-get (cdr err) :op) 'nl-ptr-ref-u64))
    (should (= (plist-get (cdr err) :offset) 1))
    (should (= (plist-get (cdr err) :size) 8))
    (should (= (plist-get (cdr err) :len) 4))))

(ert-deftest nl-safe-ptr-bounds-violation-logged ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (p (nl-safe-mock-ptr 4)))
    (should-error (nl-ptr-ref-u8 p 9))
    (let ((rec (car nl-safe--violation-log)))
      (should (eq (plist-get rec :kind) 'bounds))
      (should (eq (plist-get rec :op) 'nl-ptr-ref-u8))
      (should (= (plist-get rec :offset) 9))
      (should (= (plist-get rec :size) 1))
      (should (= (plist-get rec :len) 4)))))

;;; Fat pointer slices ---------------------------------------------------

(ert-deftest nl-safe-ptr-slice-basic ()
  (let ((p (nl-safe-mock-ptr 8)))
    (nl-ptr-set-u8 p 5 77)
    (let ((s (nl-ptr-slice p 4 4)))
      (should (nl-ptr-p s))
      (should (= (nl-ptr-len s) 4))
      (should (= (nl-ptr-ref-u8 s 1) 77)))))

(ert-deftest nl-safe-ptr-slice-write-visible-in-parent ()
  (let* ((p (nl-safe-mock-ptr 8))
         (s (nl-ptr-slice p 2 4)))
    (nl-ptr-set-u8 s 0 11)
    (should (= (nl-ptr-ref-u8 p 2) 11))))

(ert-deftest nl-safe-ptr-slice-clamped-to-parent ()
  (let ((p (nl-safe-mock-ptr 8)))
    (should-error (nl-ptr-slice p 4 5) :type 'nl-ptr-bounds-error)
    (should-error (nl-ptr-slice p 9 0) :type 'nl-ptr-bounds-error)
    (should-error (nl-ptr-slice p -1 2) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-slice-negative-len ()
  (let ((p (nl-safe-mock-ptr 8)))
    (should-error (nl-ptr-slice p 2 -1) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-slice-own-bounds ()
  (let* ((p (nl-safe-mock-ptr 8))
         (s (nl-ptr-slice p 2 4)))
    ;; Offset 4 is fine in the parent but out of the slice's range.
    (should-error (nl-ptr-ref-u8 s 4) :type 'nl-ptr-bounds-error)))

(ert-deftest nl-safe-ptr-slice-of-slice ()
  (let ((p (nl-safe-mock-ptr 16)))
    (nl-ptr-set-u8 p 10 3)
    (let* ((s1 (nl-ptr-slice p 8 8))
           (s2 (nl-ptr-slice s1 2 2)))
      (should (= (nl-ptr-ref-u8 s2 0) 3))
      (should-error (nl-ptr-slice s1 2 7) :type 'nl-ptr-bounds-error))))

(ert-deftest nl-safe-ptr-slice-full-range ()
  (let* ((p (nl-safe-mock-ptr 4))
         (s (nl-ptr-slice p 0 4)))
    (should (= (nl-ptr-len s) 4))))

;;; Generation checking (use-after-free) ---------------------------------

(ert-deftest nl-safe-ptr-generation-fresh-ok ()
  (let ((p (nl-safe-mock-ptr 4)))
    (should (= (nl-ptr-ref-u8 p 0) 0))))

(ert-deftest nl-safe-ptr-generation-after-free ()
  (let ((p (nl-safe-mock-ptr 4)))
    (nl-safe-mock-free p)
    (should-error (nl-ptr-ref-u8 p 0) :type 'nl-ptr-generation-error)
    (should-error (nl-ptr-set-u8 p 0 1) :type 'nl-ptr-generation-error)
    (should-error (nl-ptr-slice p 0 1) :type 'nl-ptr-generation-error)))

(ert-deftest nl-safe-ptr-generation-slice-shares-store ()
  (let* ((p (nl-safe-mock-ptr 8))
         (s (nl-ptr-slice p 2 4)))
    (nl-safe-mock-free p)
    (should-error (nl-ptr-ref-u8 s 0) :type 'nl-ptr-generation-error)))

(ert-deftest nl-safe-ptr-generation-error-data ()
  (let* ((p (nl-safe-mock-ptr 4))
         (err nil))
    (nl-safe-mock-free p)
    (setq err (should-error (nl-ptr-ref-u8 p 0)
                            :type 'nl-ptr-generation-error))
    (should (= (plist-get (cdr err) :expected) 0))
    (should (= (plist-get (cdr err) :actual) 1))))

(ert-deftest nl-safe-ptr-generation-violation-logged ()
  (let ((nl-safe-log-violations t)
        (nl-safe--violation-log nil)
        (p (nl-safe-mock-ptr 4)))
    (nl-safe-mock-free p)
    (should-error (nl-ptr-ref-u8 p 0))
    (let ((rec (car nl-safe--violation-log)))
      (should (eq (plist-get rec :kind) 'generation))
      (should (= (plist-get rec :expected) 0))
      (should (= (plist-get rec :actual) 1)))))

(ert-deftest nl-safe-ptr-backend-indirection ()
  "Accessors route every memory touch through `nl-safe-ptr-backend'."
  (let ((ops nil))
    (let ((nl-safe-ptr-backend
           (lambda (op _base &optional a b)
             (setq ops (cons (list op a b) ops))
             (cond ((eq op 'generation) nil) ; nil skips the check
                   ((eq op 'ref-u8) 42)
                   (t 0)))))
      (let ((p (nl-safe-mock-ptr 8)))
        (setq ops nil)
        (should (= (nl-ptr-ref-u8 p 3) 42))
        (should (equal (car ops) '(ref-u8 3 nil)))
        (nl-ptr-set-u8 p 1 7)
        (should (equal (car ops) '(set-u8 1 7)))))))

(ert-deftest nl-safe-ptr-backend-nil-generation-skips-check ()
  "A backend returning nil for `generation' disables UAF checking."
  (let ((nl-safe-ptr-backend
         (lambda (op _base &optional _a _b)
           (cond ((eq op 'generation) nil)
                 ((eq op 'ref-u8) 9)
                 (t 0)))))
    ;; Generation 999 can never match a real counter; nil skips.
    (let ((p (nl-safe--ptr-make 'opaque 4 999)))
      (should (= (nl-ptr-ref-u8 p 0) 9)))))

;;; Unsafe boundary ------------------------------------------------------

(ert-deftest nl-safe-ptr-make-allowed-when-not-strict ()
  (should (nl-ptr-p (nl-ptr-make (nl-safe-mock-alloc 4) 4 0))))

(ert-deftest nl-safe-ptr-make-rejected-under-strict ()
  (let ((nl--strict t))
    (should-error (macroexpand '(nl-ptr-make b 4 0)))))

(ert-deftest nl-safe-ptr-make-inside-unsafe-under-strict ()
  (let ((nl--strict t))
    (should (nl-ptr-p
             (eval '(nl-unsafe
                     (nl-ptr-make (nl-safe-mock-alloc 4) 4 0)))))))

(ert-deftest nl-safe-unsafe-rewrites-nested-forms ()
  (let ((nl--strict t))
    (should (nl-ptr-p
             (eval '(nl-unsafe
                     (let ((n 4))
                       (nl-ptr-make (nl-safe-mock-alloc n) n 0))))))))

(ert-deftest nl-safe-unsafe-returns-last-value ()
  (should (= (nl-unsafe 1 2 3) 3)))

(ert-deftest nl-safe-unsafe-does-not-rewrite-quoted ()
  (should (equal (nl-unsafe '(nl-ptr-make 1 2 3))
                 '(nl-ptr-make 1 2 3))))

(ert-deftest nl-safe-unsafe-empty-body ()
  (should (eq (nl-unsafe) nil)))

;;; Unsafe primitive inventory (Doc 170 section 4.3 acceptance) ----------

(ert-deftest nl-safe-unsafe-inventory-capped-at-20 ()
  (should (<= (length nl-safe-unsafe-primitives) 20)))

(ert-deftest nl-safe-unsafe-inventory-contents ()
  (should (memq 'nl-ptr-make nl-safe-unsafe-primitives))
  (should (memq 'syscall-direct nl-safe-unsafe-primitives))
  (should (memq 'alloc-bytes nl-safe-unsafe-primitives))
  (let ((rest nl-safe-unsafe-primitives))
    (while rest
      (should (symbolp (car rest)))
      (setq rest (cdr rest)))))

(ert-deftest nl-safe-unsafe-inventory-no-duplicates ()
  (let ((rest nl-safe-unsafe-primitives))
    (while rest
      (should-not (memq (car rest) (cdr rest)))
      (setq rest (cdr rest)))))

;;; Disable flag: expansion identity (Doc 170 section 9) -----------------

(ert-deftest nl-safe-disabled-borrow-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-with-borrow (b c) (aref b 0))))
                 '(let ((b (nl-safe--cell-value c))) (aref b 0)))))

(ert-deftest nl-safe-disabled-borrow-mut-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-with-borrow-mut (b c) (aset b 0 1))))
                 '(let ((b (nl-safe--cell-value c))) (aset b 0 1)))))

(ert-deftest nl-safe-disabled-ref-u8-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-ptr-ref-u8 p 3)))
                 '(funcall nl-safe-ptr-backend 'ref-u8 (aref p 1) 3))))

(ert-deftest nl-safe-disabled-set-u8-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-ptr-set-u8 p 3 9)))
                 '(funcall nl-safe-ptr-backend 'set-u8 (aref p 1) 3 9))))

(ert-deftest nl-safe-disabled-ref-u64-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-ptr-ref-u64 p 0)))
                 '(funcall nl-safe-ptr-backend 'ref-u64 (aref p 1) 0))))

(ert-deftest nl-safe-disabled-slice-expansion-identity ()
  (should (equal (let ((nl-safe--enabled nil))
                   (macroexpand '(nl-ptr-slice p 2 4)))
                 '(nl-safe--ptr-slice-unchecked p 2 4))))

(ert-deftest nl-safe-enabled-expansion-differs ()
  (should-not (equal (macroexpand '(nl-with-borrow (b c) (aref b 0)))
                     '(let ((b (nl-safe--cell-value c))) (aref b 0))))
  (should (equal (macroexpand '(nl-ptr-ref-u8 p 3))
                 '(nl-safe--ptr-ref-u8 p 3))))

;;; Disable flag: unchecked execution ------------------------------------

(ert-deftest nl-safe-disabled-borrow-executes ()
  (let ((nl-safe--enabled nil))
    (should (= (eval '(let ((c (nl-cell 5)))
                        (nl-with-borrow (v c) (+ v 1))))
               6))))

(ert-deftest nl-safe-disabled-borrow-mut-executes ()
  (let ((nl-safe--enabled nil))
    (should (= (eval '(let ((c (nl-cell (make-vector 2 0))))
                        (nl-with-borrow-mut (v c) (aset v 0 8))
                        (nl-with-borrow (v c) (aref v 0))))
               8))))

(ert-deftest nl-safe-disabled-no-borrow-tracking ()
  "With checks off, aliasing violations are not detected (by design)."
  (let ((nl-safe--enabled nil))
    (should (= (eval '(let ((c (nl-cell 1)))
                        (nl-with-borrow (a c)
                          (nl-with-borrow-mut (b c) (+ a b)))))
               2))))

(ert-deftest nl-safe-disabled-no-state-writes ()
  (let ((nl-safe--enabled nil))
    (should (= (eval '(let ((c (nl-cell 1)))
                        (nl-with-borrow (_v c) (aref c 2))))
               0))))

(ert-deftest nl-safe-disabled-ptr-executes ()
  (let ((nl-safe--enabled nil))
    (should (= (eval '(let ((p (nl-safe-mock-ptr 4)))
                        (nl-ptr-set-u8 p 1 42)
                        (nl-ptr-ref-u8 p 1)))
               42))))

;;; nl-cell-set write-back (2026-08-15 code review fix) ----------------

(ert-deftest nl-safe-cell-set-writes-back-under-exclusive-borrow ()
  "setq on the borrow VAR is a snapshot no-op; nl-cell-set writes back."
  (let ((cell (nl-cell 1)))
    (nl-with-borrow-mut (v cell)
      (setq v 99)                      ; snapshot only, by design
      (nl-cell-set cell 42))
    (should (= 99 99))                 ; silence unused-var intent
    (nl-with-borrow (v cell)
      (should (equal v 42)))))

(ert-deftest nl-safe-cell-set-outside-exclusive-borrow-errors ()
  (let ((cell (nl-cell 1)))
    (should-error (nl-cell-set cell 2) :type 'nl-borrow-error)
    (nl-with-borrow (_v cell)
      (should-error (nl-cell-set cell 2) :type 'nl-borrow-error))
    (nl-with-borrow (v cell)
      (should (equal v 1)))))

(ert-deftest nl-safe-cell-set-type-error ()
  (should-error (nl-cell-set [not-a-cell] 1) :type 'nl-type-error))

(ert-deftest nl-safe-cell-set-return-value ()
  (let ((cell (nl-cell nil)))
    (nl-with-borrow-mut (_v cell)
      (should (equal (nl-cell-set cell 'stored) 'stored)))))

(provide 'nl-safe-test)

;;; nl-safe-test.el ends here
