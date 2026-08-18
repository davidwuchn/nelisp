;;; service-checked.el --- the same service, with the buffer under a borrow -*- lexical-binding: t; -*-

;;; Commentary:

;; `service.el' keeps the bytes it has read but not yet parsed in a
;; plain variable that two functions mutate.  That is the shape aliasing
;; bugs live in: one function appends to it while another consumes from
;; it, and nothing says which of them owns it at any moment.
;;
;; This variant puts that buffer in a borrow cell.  It exists as a
;; second file rather than a replacement so the recipe can be measured
;; both ways -- the interesting number for anyone considering nl-safe is
;; not the cost of a borrow but the cost of adopting it in something
;; that does real work.
;;
;;     nelisp --load recipes/stdio-service/skeleton/service-checked.el
;;
;; Granularity is the whole point.  A borrow is taken once per line
;; read, around fill-and-scan together, not once per byte or once per
;; access.  Measured per access a borrow costs about 46x an unchecked
;; read; measured per unit of work it disappears into the work.  Adopting
;; nl-safe is therefore a question about where the boundaries of a unit
;; of work are, not a question about whether the checks are affordable.

;;; Code:

(load "packages/nl-prelude/src/nl-prelude.el" nil t)
(load "packages/nl-safe/src/nl-safe.el" nil t)

(defvar service-checked-chunk-size 4096
  "Bytes requested per `read-stdin-bytes' call.")

;; The cell holds a one-slot vector rather than the string itself: a
;; borrow protects a mutable container, and replacing a variable's value
;; is not what it is for.
(nl-defcell service-checked-pending (vector ""))

(defun service-checked-take-line ()
  "Return the next complete input line, or nil at end of input.

One exclusive borrow covers reading, appending and splitting.  The
alternative -- a borrow per `read-stdin-bytes' call -- would take the
same checks several times for one line and buy nothing: no other code
can observe the buffer between them anyway."
  (nl-with-borrow-mut (slot service-checked-pending)
    (let ((idx (string-search "\n" (aref slot 0)))
          (open t)
          (line nil))
      (while (and (null idx) open)
        (let ((chunk (read-stdin-bytes service-checked-chunk-size)))
          (if chunk
              (progn
                (aset slot 0 (concat (aref slot 0) chunk))
                (setq idx (string-search "\n" (aref slot 0))))
            (setq open nil))))
      (cond
       (idx
        (setq line (substring (aref slot 0) 0 idx))
        (aset slot 0 (substring (aref slot 0) (1+ idx))))
       ((> (length (aref slot 0)) 0)
        (setq line (aref slot 0))
        (aset slot 0 "")))
      line)))

(defun service-checked-buffered ()
  "Return how many bytes are held but not yet parsed.
A shared borrow: reading the buffer does not need exclusive access, and
saying so is the point of having two kinds."
  (nl-with-borrow (slot service-checked-pending)
    (length (aref slot 0))))

(defun service-checked-write (form)
  "Write FORM as one response line."
  (prin1 form)
  (terpri))

(defun service-checked-handle (request)
  "Return the response form for REQUEST."
  (cond
   ((not (consp request))
    (list 'error "request must be a list"))
   ((eq (car request) 'ping)
    (list 'pong (car (cdr request))))
   ((eq (car request) 'echo)
    (cons 'echo (cdr request)))
   ((eq (car request) 'add)
    (list 'sum (+ (car (cdr request)) (car (cdr (cdr request))))))
   ((eq (car request) 'buffered)
    (list 'buffered (service-checked-buffered)))
   ((eq (car request) 'stats)
    (list 'used (car (cdr (cdr (nelisp--arena-stats))))))
   ;; Deliberately illegal: an exclusive borrow while a shared one is
   ;; live.  Kept as a request so the smoke can prove the checks are
   ;; running -- a service whose borrows are all legal looks exactly
   ;; like a service with no checks at all.
   ((eq (car request) 'conflict)
    (condition-case _err
        (nl-with-borrow (_a service-checked-pending)
          (nl-with-borrow-mut (_b service-checked-pending)
            (list 'conflict 'missed)))
      (nl-borrow-error (list 'conflict 'signalled))))
   (t
    (list 'error (format "unknown request: %s" (car request))))))

(defun service-checked-main ()
  "Serve requests until `(quit)' or end of input."
  (let ((line (service-checked-take-line))
        (running t))
    (while (and running line)
      (let ((parsed (car (ignore-errors (read-from-string line)))))
        (cond
         ((null parsed)
          (service-checked-write (list 'error "unreadable request")))
         ((and (consp parsed) (eq (car parsed) 'quit))
          (service-checked-write (list 'bye))
          (setq running nil))
         (t
          (service-checked-write (service-checked-handle parsed)))))
      (when running
        (setq line (service-checked-take-line)))))
  'service-eof)

(service-checked-main)

;;; service-checked.el ends here
