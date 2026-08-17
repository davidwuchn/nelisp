;;; service.el --- a NeLisp stdio service, minimal but complete -*- lexical-binding: t; -*-

;;; Commentary:

;; Protocol: one s-expression per line on stdin, one s-expression per
;; line on stdout.  Run it as:
;;
;;     nelisp --load service.el
;;
;; and not as `nelisp service.el': the positional form loads through a
;; leaner substrate where `string-search' is void, so the service dies
;; on its first line.  Measured, not assumed -- see PITFALLS.md.
;;
;; `--load' prints the loaded file's return value when it finishes, so
;; the stream always ends with one extra line.  Rather than fight that,
;; `service-main' returns `service-eof' and that extra line becomes the
;; documented end-of-stream marker.
;;
;; Why s-expressions rather than JSON: `read-from-string' is in the
;; standalone runtime and `json-encode' is not (it lives in the
;; nelisp-json package).  Framing requests as Lisp means no parser to
;; write and no dependency to load.
;;
;; Why lines rather than a length prefix: a line is what a host process
;; can write with `fprintf' and flush, and what a shell can generate in
;; a test.  Length prefixes are better once the payload can contain
;; newlines; at that point change `service-next-line' and nothing else.

;;; Code:

(defvar service-chunk-size 4096
  "Bytes requested per `read-stdin-bytes' call.")

(defvar service--pending ""
  "Input read from stdin that does not yet form a complete line.")

(defun service--fill ()
  "Read one chunk from stdin.  Return nil at end of file.

`read-stdin-bytes' is the runtime's only stdin primitive: `read' here
supports string streams only, and `read-string' does not exist.  It
returns whatever the underlying read(2) produced, so a chunk boundary
can fall anywhere — including mid-line, which is why this function
appends to a buffer instead of returning the chunk."
  (let ((chunk (read-stdin-bytes service-chunk-size)))
    (when chunk
      (setq service--pending (concat service--pending chunk))
      t)))

(defun service-next-line ()
  "Return the next complete input line, or nil at end of input."
  (let ((idx (string-search "\n" service--pending))
        (open t))
    (while (and (null idx) open)
      (if (service--fill)
          (setq idx (string-search "\n" service--pending))
        (setq open nil)))
    (cond
     (idx
      (let ((line (substring service--pending 0 idx)))
        (setq service--pending (substring service--pending (1+ idx)))
        line))
     ;; A final line with no trailing newline is still a request.
     ((> (length service--pending) 0)
      (let ((line service--pending))
        (setq service--pending "")
        line))
     (t nil))))

(defun service-write (form)
  "Write FORM as one response line."
  (prin1 form)
  (terpri))

(defun service-handle (request)
  "Return the response form for REQUEST.

Replace this function; everything above and below it is transport."
  (cond
   ((not (consp request))
    (list 'error "request must be a list"))
   ((eq (car request) 'ping)
    (list 'pong (car (cdr request))))
   ((eq (car request) 'echo)
    (cons 'echo (cdr request)))
   ((eq (car request) 'add)
    (list 'sum (+ (car (cdr request)) (car (cdr (cdr request))))))
   (t
    (list 'error (format "unknown request: %s" (car request))))))

(defun service-main ()
  "Serve requests until `(quit)' or end of input."
  (let ((line (service-next-line))
        (running t))
    (while (and running line)
      (let ((parsed (car (ignore-errors (read-from-string line)))))
        (cond
         ;; An unreadable line gets an answer instead of killing the
         ;; service.  A host that can crash its worker by sending one
         ;; bad byte is a host that will.
         ((null parsed)
          (service-write (list 'error "unreadable request")))
         ((and (consp parsed) (eq (car parsed) 'quit))
          (service-write (list 'bye))
          (setq running nil))
         (t
          (service-write (service-handle parsed)))))
      (when running
        (setq line (service-next-line)))))
  ;; Printed by `--load' as the final line: see the commentary.
  'service-eof)

(service-main)

;;; service.el ends here
