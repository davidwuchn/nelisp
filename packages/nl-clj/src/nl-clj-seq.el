;;; nl-clj-seq.el --- Generic seq/collection API for nl-clj -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 194 §4.7 (minimal slice; laziness itself deferred to a later
;; phase per this package's own build-first brief) plus the
;; polymorphic operations Doc 194 §4.1/§4.2 each describe for their
;; own collection: this file is the single place every nl-clj public
;; function that works across MORE than one collection type lives --
;; `nl-clj-seq'/`first'/`rest'/`next'/`cons'/`into'/`map'/`filter'/
;; `reduce'/`count'/`conj'/`assoc'/`get'/`nth'/`peek'/`pop'/`vec'/
;; `subvec'/`contains?'/`equal'/`hash', plus the map-only `dissoc' and
;; set-only `disj' (each needs the OTHER collection modules' internals
;; to dispatch, so they cannot live in `nl-clj-vector.el'/
;; `nl-clj-hash.el' themselves without an upward dependency).  Every
;; function here is a single, real Clojure name -- exactly like real
;; Clojure, where `conj'/`assoc'/`get'/`count'/`seq'/`first'/`rest'
;; are themselves single polymorphic functions, not one per collection
;; type.
;;
;; Eager, not lazy (this package's own build-first brief, following
;; Doc 194 §6's own ranking): `nl-clj-seq' materializes a plain Elisp
;; list up front rather than returning a lazy view.  `nl-clj-map'/
;; `nl-clj-filter'/`nl-clj-reduce' walk that list with a plain `while'
;; loop -- inherently stack-safe with zero recursion, so unlike Doc
;; 194 §4.7's (deferred) lazy-seq walk, `nl-loop'/`nl-recur' are not
;; needed here to avoid blowing the interpreter's own call stack.
;;
;; A named, documented divergence from Clojure (Doc 194 §4.7's own
;; discipline: name it, do not hide it): Clojure's `rest' and `next'
;; are observably different only because Clojure distinguishes an
;; empty-but-not-nil `()' from `nil'.  This package's seq
;; representation IS a plain Elisp list, where empty is always
;; literal `nil' -- there is no separate "empty, not nil" seq object
;; -- so `nl-clj-rest' and `nl-clj-next' are behaviorally identical
;; here.  Both are still defined, under their own names, for full
;; Clojure API-surface parity.
;;
;; `nl-clj-equal'/`nl-clj-hash' exist because plain `equal'/
;; `sxhash-equal' walk a tagged vector *structurally* (ROOT/TAIL/SHIFT
;; element by element), which is a different question from Clojure's
;; own logical collection equality (comparing the *sequence of
;; elements*, regardless of internal tree shape) -- Doc 194 §3.2's
;; named correctness trap.  Passing an nl-clj collection as a key into
;; a *plain* `(make-hash-table :test 'equal)' still silently uses the
;; wrong notion (tree-shape, not content) -- `define-hash-table-test'
;; is void-function on this substrate (Doc 194 §2.3), so there is no
;; way to register the right one as a real hash-table `:test' at all;
;; this is a named, accepted footgun, not solved here.

;;; Code:

(require 'nl-clj-core)
(require 'nl-clj-atom)
(require 'nl-clj-vector)
(require 'nl-clj-hash)

;;;; seq / first / rest / next / cons --------------------------------------

(defun nl-clj-seq (coll)
  "Return a seq (a plain Elisp list) over COLL, or nil if COLL is empty.
COLL may be an nl-clj vector, map, set, an ordinary Elisp list (or
nil), or -- a deliberate bonus, costing nothing given this dispatch --
a plain Elisp vector.  A map's seq is a list of (KEY . VAL) conses; a
set's seq is a list of its elements."
  (cond
   ((null coll) nil)
   ((nl-clj-vector-p coll) (nl-clj-vector--to-list coll))
   ((nl-clj-map-p coll) (nl-clj-hash--map-entries coll))
   ((nl-clj-set-p coll) (nl-clj-hash--set-elements coll))
   ((nl-clj-atom-p coll) (signal 'nl-clj-type-error (list 'nl-clj-seq "atoms are not seqable" coll)))
   ((consp coll) coll)
   ((vectorp coll) (append coll nil))
   (t (signal 'nl-clj-type-error (list 'nl-clj-seq "not seqable" coll)))))

(defun nl-clj-first (coll)
  "Return the first element of COLL's seq, or nil if empty."
  (car (nl-clj-seq coll)))

(defun nl-clj-rest (coll)
  "Return COLL's seq minus its first element (nil, not an error, if COLL
has 0 or 1 elements).  See this file's Commentary re: `nl-clj-next'."
  (cdr (nl-clj-seq coll)))

(defun nl-clj-next (coll)
  "Same as `nl-clj-rest' in this implementation -- see this file's
Commentary for the named, deliberate divergence from Clojure this is."
  (cdr (nl-clj-seq coll)))

(defun nl-clj-cons (x coll)
  "Return a new seq: X followed by COLL's own seq."
  (cons x (nl-clj-seq coll)))

;;;; count -------------------------------------------------------------------

(defun nl-clj-count (coll)
  "Return the number of elements in COLL."
  (cond
   ((null coll) 0)
   ((or (nl-clj-vector-p coll) (nl-clj-map-p coll) (nl-clj-set-p coll)) (aref coll 1))
   ((consp coll) (length coll))
   ((vectorp coll) (length coll))
   (t (signal 'nl-clj-type-error (list 'nl-clj-count coll)))))

;;;; get / contains? / nth -----------------------------------------------

(defun nl-clj-get (coll k &optional default)
  "Return the value at key/index K in COLL, or DEFAULT (nil) if absent.
Vector: K is an index, in range or DEFAULT, never an error.  Map: K is
a key.  Set: returns the matching element itself (Clojure's own `get'
contract for sets) or DEFAULT."
  (cond
   ((null coll) default)
   ((nl-clj-vector-p coll)
    (if (and (integerp k) (>= k 0) (< k (aref coll 1)))
        (nl-clj-vector--nth coll k)
      default))
   ((nl-clj-map-p coll) (nl-clj-hash--map-get coll k default))
   ((nl-clj-set-p coll)
    (let ((r (nl-clj-hash--map-get coll k nl-clj--not-found)))
      (if (eq r nl-clj--not-found) default k)))
   (t default)))

(defun nl-clj-contains? (coll k)
  "Return non-nil iff COLL has an entry for key/index K (vector: index
in range; map/set: key present).  Unlike `nl-clj-get', this can
distinguish \"present with a nil value\" from \"absent\"."
  (cond
   ((null coll) nil)
   ((nl-clj-vector-p coll) (and (integerp k) (>= k 0) (< k (aref coll 1))))
   ((or (nl-clj-map-p coll) (nl-clj-set-p coll))
    (not (eq (nl-clj-hash--map-get coll k nl-clj--not-found) nl-clj--not-found)))
   (t nil)))

(defun nl-clj-nth (coll n &optional default)
  "Return the Nth (0-based) element of COLL.  Signals `nl-clj-index-error'
when N is out of range and no DEFAULT is given (Clojure's own `nth'
contract -- unlike `nl-clj-get', out of range is an error by default)."
  (cond
   ((nl-clj-vector-p coll)
    (if (and (>= n 0) (< n (aref coll 1)))
        (nl-clj-vector--nth coll n)
      (or default (signal 'nl-clj-index-error (list 'nl-clj-nth n (aref coll 1))))))
   (t (let ((s (nl-clj-seq coll)) (i n))
        (while (and s (> i 0)) (setq s (cdr s)) (setq i (1- i)))
        (if (and s (= i 0))
            (car s)
          (or default (signal 'nl-clj-index-error (list 'nl-clj-nth n))))))))

;;;; conj / assoc / dissoc / disj -----------------------------------------

(defun nl-clj-hash--map-conj-entry (m entry)
  "Add ENTRY -- a (KEY . VAL) cons or a 2-element [KEY VAL] vector -- to M."
  (cond
   ((and (vectorp entry) (= (length entry) 2))
    (nl-clj-hash--map-assoc m (aref entry 0) (aref entry 1)))
   ((consp entry) (nl-clj-hash--map-assoc m (car entry) (cdr entry)))
   (t (signal 'nl-clj-error (list 'nl-clj-conj "map conj expects a (k . v) or [k v] entry" entry)))))

(defun nl-clj-conj-1 (coll x)
  "Add the single item X to COLL, per COLL's own type: vector appends,
list/nil prepends, map takes a (k . v)/[k v] entry, set adds X itself."
  (cond
   ((nl-clj-vector-p coll) (nl-clj-vector--conj coll x))
   ((nl-clj-map-p coll) (nl-clj-hash--map-conj-entry coll x))
   ((nl-clj-set-p coll) (nl-clj-hash--set-conj coll x))
   ((or (null coll) (consp coll)) (cons x coll))
   (t (signal 'nl-clj-type-error (list 'nl-clj-conj coll)))))

(defun nl-clj-conj (coll &rest xs)
  "Add each of XS to COLL, left to right; see `nl-clj-conj-1'."
  (dolist (x xs) (setq coll (nl-clj-conj-1 coll x)))
  coll)

(defun nl-clj-assoc-1 (coll k v)
  "Set key/index K of COLL to V.  Vector: K in [0, count] (== count
extends by one).  Map: K is any key."
  (cond
   ((nl-clj-vector-p coll) (nl-clj-vector--assoc-n coll k v))
   ((nl-clj-map-p coll) (nl-clj-hash--map-assoc coll k v))
   (t (signal 'nl-clj-type-error (list 'nl-clj-assoc coll)))))

(defun nl-clj-assoc (coll k v &rest kvs)
  "Set K to V in COLL, and each further KEY VAL pair in KVS, left to right."
  (let ((result (nl-clj-assoc-1 coll k v)))
    (while kvs
      (setq result (nl-clj-assoc-1 result (car kvs) (cadr kvs)))
      (setq kvs (cddr kvs)))
    result))

(defun nl-clj-dissoc (m k &rest ks)
  "Remove K, and each further key in KS, from map M.
Removing an absent key is a no-op returning M itself, `eq'-identical
(Doc 194 §4.2)."
  (unless (nl-clj-map-p m) (signal 'nl-clj-type-error (list 'nl-clj-dissoc m)))
  (let ((result (nl-clj-hash--map-dissoc m k)))
    (dolist (kk ks) (setq result (nl-clj-hash--map-dissoc result kk)))
    result))

(defun nl-clj-disj (s x &rest xs)
  "Remove X, and each further item in XS, from set S.  Set analog of
`nl-clj-dissoc'; same `eq'-identical no-op guarantee on an absent item."
  (unless (nl-clj-set-p s) (signal 'nl-clj-type-error (list 'nl-clj-disj s)))
  (let ((result (nl-clj-hash--set-disj s x)))
    (dolist (xx xs) (setq result (nl-clj-hash--set-disj result xx)))
    result))

;;;; peek / pop (vector: last; list: first -- Clojure's own polymorphism) -

(defun nl-clj-peek (coll)
  "Return the \"top\" of COLL without removing it: a vector's last
element, or a list's first -- Clojure's own polymorphic `peek'.  nil
on an empty vector or an empty/nil list (Clojure's own `peek' contract:
unlike `pop', `peek' on empty is not an error)."
  (cond
   ((null coll) nil)
   ((nl-clj-vector-p coll) (if (= (aref coll 1) 0) nil (nl-clj-vector--nth coll (1- (aref coll 1)))))
   ((consp coll) (car coll))
   (t (signal 'nl-clj-type-error (list 'nl-clj-peek coll)))))

(defun nl-clj-pop (coll)
  "Remove the \"top\" of COLL: a vector's last element, or a list's
first.  Signals `nl-clj-index-error' on an empty vector or nil list
(Clojure's own `pop' contract: an error, not a silent no-op)."
  (cond
   ((nl-clj-vector-p coll) (nl-clj-vector--pop coll))
   ((consp coll) (cdr coll))
   ((null coll) (signal 'nl-clj-index-error (list 'nl-clj-pop "empty")))
   (t (signal 'nl-clj-type-error (list 'nl-clj-pop coll)))))

;;;; into / vec / subvec ----------------------------------------------------

(defun nl-clj-into (to from)
  "Conj every element of FROM's seq into TO, in order; return the result."
  (let ((result to))
    (dolist (x (nl-clj-seq from)) (setq result (nl-clj-conj-1 result x)))
    result))

(defun nl-clj-vec (coll)
  "Return a persistent vector containing the elements of seqable COLL."
  (if (nl-clj-vector-p coll)
      coll
    (let ((v (nl-clj-vector--empty)))
      (dolist (x (nl-clj-seq coll)) (setq v (nl-clj-vector--conj v x)))
      v)))

(defun nl-clj-subvec (v start &optional end)
  "Return a NEW persistent vector holding V's elements in [START, END).
END defaults to V's count.  A deliberate divergence from Clojure's own
O(1) offset/end-aware view type -- Doc 194 §4.1 explicitly defers that
optimization; this is an eager O(k) rebuild, correctness-first."
  (unless (nl-clj-vector-p v) (signal 'nl-clj-type-error (list 'nl-clj-subvec v)))
  (let* ((count (aref v 1)) (e (or end count)))
    (unless (and (>= start 0) (<= start e) (<= e count))
      (signal 'nl-clj-index-error (list 'nl-clj-subvec start end count)))
    (let ((result (nl-clj-vector--empty)) (i start))
      (while (< i e)
        (setq result (nl-clj-vector--conj result (nl-clj-vector--nth v i)))
        (setq i (1+ i)))
      result)))

;;;; map / filter / reduce (eager) ------------------------------------------

(defun nl-clj-map (f coll)
  "Eagerly apply F to every element of COLL's seq; return a plain Elisp
list of the results.  Eager for this phase -- Doc 194 §4.7 defers a
lazy version to a later phase."
  (mapcar f (nl-clj-seq coll)))

(defun nl-clj-filter (pred coll)
  "Return a plain Elisp list of COLL's elements for which PRED is non-nil."
  (let (acc)
    (dolist (x (nl-clj-seq coll)) (when (funcall pred x) (push x acc)))
    (nreverse acc)))

(defun nl-clj-reduce (f init coll)
  "Left fold: (f (f (f INIT x1) x2) x3) ... over COLL's seq.
A plain `while' walk, not recursion -- stack-safe over an arbitrarily
long seq for free, with no need for `nl-loop'/`nl-recur' (those are
load-bearing only for Doc 194 §4.7's deferred *lazy* walk, whose
producer closures cannot be flattened into an ordinary loop the way an
already-eager seq can)."
  (let ((acc init) (s (nl-clj-seq coll)))
    (while s
      (setq acc (funcall f acc (car s)))
      (setq s (cdr s)))
    acc))

;;;; Content equality / hash (Doc 194 §3.2) ---------------------------------

(defun nl-clj-collection-p (x)
  "Return non-nil iff X is an nl-clj vector, map, or set."
  (or (nl-clj-vector-p x) (nl-clj-map-p x) (nl-clj-set-p x)))

(defun nl-clj--equal-seqs (sa sb)
  (while (and sa sb (nl-clj-equal (car sa) (car sb)))
    (setq sa (cdr sa) sb (cdr sb)))
  (and (null sa) (null sb)))

(defun nl-clj--equal-colls (a b)
  (cond
   ((and (nl-clj-vector-p a) (nl-clj-vector-p b))
    (and (= (aref a 1) (aref b 1))
         (nl-clj--equal-seqs (nl-clj-seq a) (nl-clj-seq b))))
   ((and (nl-clj-map-p a) (nl-clj-map-p b))
    (and (= (aref a 1) (aref b 1))
         (catch 'nl-clj--neq
           (dolist (pair (nl-clj-hash--map-entries a) t)
             (let ((bv (nl-clj-hash--map-get b (car pair) nl-clj--not-found)))
               (when (or (eq bv nl-clj--not-found) (not (nl-clj-equal (cdr pair) bv)))
                 (throw 'nl-clj--neq nil)))))))
   ((and (nl-clj-set-p a) (nl-clj-set-p b))
    (and (= (aref a 1) (aref b 1))
         (catch 'nl-clj--neq
           (dolist (x (nl-clj-hash--set-elements a) t)
             (unless (nl-clj-contains? b x) (throw 'nl-clj--neq nil))))))
   (t nil))) ;; different collection kinds are never nl-clj-equal

(defun nl-clj-equal (a b)
  "Content equality across nl-clj collection types, and plain `equal'
for everything else.  See this file's Commentary for why this is NOT
`equal' for nl-clj collections."
  (cond
   ((and (nl-clj-collection-p a) (nl-clj-collection-p b)) (nl-clj--equal-colls a b))
   ((or (nl-clj-collection-p a) (nl-clj-collection-p b)) nil)
   (t (equal a b))))

(defconst nl-clj--hash-space (1- (ash 1 32))
  "Every combined hash value below is kept within this 32-bit space.
Doc 194 §2.2 measured, against a built `target/nelisp', that `+'/`-'/
`*' do NOT auto-promote past fixnum range on this substrate today
(bignum arithmetic is Doc 190 Phase B, not shipped -- a value that
overflows signals `overflow-error', full stop).  A raw `sxhash-equal'
result can be up to ~61 bits; multiplying two such values together (or
multiplying one by a small constant across many `dolist' iterations
without ever re-bounding it) can overflow well before any final
`logand' would clamp it.  Every operand is masked to this 32-bit space
BEFORE each arithmetic step, not only after, so no intermediate value
ever approaches `most-positive-fixnum' -- the standalone smoke caught
exactly this defect once (`overflow-error' from the unmasked version)
before this fix.")

(defun nl-clj--hash-mix (h x-hash)
  "Combine accumulator H with the next element's X-HASH, staying inside
`nl-clj--hash-space' at every step (see its docstring for why)."
  (logand (+ (* (logand h nl-clj--hash-space) 31) (logand x-hash nl-clj--hash-space))
          nl-clj--hash-space))

(defun nl-clj--hash-seq (lst seed)
  (let ((h (logand seed nl-clj--hash-space)))
    (dolist (x lst) (setq h (nl-clj--hash-mix h (nl-clj-hash x))))
    h))

(defun nl-clj--hash-unordered (pairs seed)
  "Order-independent combination (so a map/set's own `nl-clj-hash' does
not depend on HAMT bucket layout order, which is not part of its
logical identity).  Multiplies two masked, bounded operands (never two
raw up-to-61-bit `sxhash-equal' results together) for the same
overflow-safety reason as `nl-clj--hash-mix'."
  (let ((h (logand seed nl-clj--hash-space)))
    (dolist (p pairs)
      (let ((kh (1+ (logand (nl-clj-hash (car p)) nl-clj--hash-space)))
            (vh (1+ (logand (nl-clj-hash (cdr p)) nl-clj--hash-space))))
        (setq h (logxor h (logand (* kh vh) nl-clj--hash-space)))))
    h))

(defun nl-clj-hash (x)
  "Content hash of X, consistent with `nl-clj-equal'.  NOT `sxhash-equal'
on X's raw representation for an nl-clj collection -- two logically
equal collections need not share internal tree shape (Doc 194 §3.2)."
  (cond
   ((nl-clj-vector-p x) (nl-clj--hash-seq (nl-clj-seq x) -415))
   ((nl-clj-map-p x) (nl-clj--hash-unordered (nl-clj-hash--map-entries x) 7))
   ((nl-clj-set-p x)
    (nl-clj--hash-unordered (mapcar (lambda (e) (cons e t)) (nl-clj-hash--set-elements x)) 13))
   (t (sxhash-equal x))))

(provide 'nl-clj-seq)

;;; nl-clj-seq.el ends here
