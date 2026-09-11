;;;; tests/example-value-error.scm
;;;;
;;;; Phase 9 port of alibfyaml's own example_value_error.adb: parse a
;;;; YAML file that is syntactically fine but has a malformed value
;;;; for a typed field, and report it in gcc's own diagnostic format:
;;;; "file:line:column: error: message".
;;;;
;;;; Unlike a syntax error (example-syntax-error.scm), there IS a
;;;; parsed tree here -- the document parses fine; it's a specific
;;;; node's content that's the wrong shape. The (exn slibfyaml data)
;;;; condition's own message carries only the offending text, no
;;;; location by itself -- this is exactly the motivating case for
;;;; node-location (see PLAN.md's Phase 8 writeup): look up the node
;;;; *before* calling the typed accessor on it, so it's still in scope
;;;; to report a location alongside the data condition's message if
;;;; that call fails.
;;;;
;;;; Shows the same malformed value parsed two ways -- from a file
;;;; (document-parse-file) and from an in-memory string
;;;; (document-parse-string) -- to make the one real difference
;;;; between them obvious: the "file" field. Unlike the syntax-error
;;;; case, node-location has no file component at all -- it is purely
;;;; (line, column), the same either way (confirmed live) -- there is
;;;; no library-supplied override to fall back on here;
;;;; "(string-in-memory)" below is this example's own choice of label
;;;; for the string case, not something node-location or the data
;;;; condition hands back.
;;;;
;;;; Run as: ./example-value-error [file]  (defaults to value_error.yaml)

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))
(import (chicken process-context))

(define input-file
  (let ((args (command-line-arguments)))
    (if (pair? args) (car args) "value_error.yaml")))

;; Matches value_error.yaml's own content exactly, so both cases below
;; report the same line/column for the same malformed value -- only
;; the "file" label differs.
(define malformed-text "name: widget\ncount: banana\n")

(define saw-error #f)

;; Report a data condition caught on n in gcc format, falling back to
;; just "label: error: message" if n has no location (e.g. it was
;; built via document-create-scalar rather than parsed).
(define (report file-label n message)
  (if (node-has-location? n)
      (let-values (((line column) (node-location n)))
        (print file-label ":" line ":" column ": error: " message))
      (print file-label ": error: " message)))

;; Look up "/count" in doc, report and record failure if it's missing
;; or malformed, using file-label to report it.
(define (check-count file-label doc)
  (let ((count (node-by-path (document-root doc) "/count")))
    (if (not (node-valid? count))
        (begin
          (print file-label ": no \"count\" key")
          (set! saw-error #t))
        (condition-case
         (print "count = " (node-integer-value count))
         (e (exn slibfyaml data)
            (report file-label count (get-condition-property e 'exn 'message))
            (set! saw-error #t))))))

(print "=== Parsing from a file ===")
(with-document (doc (document-parse-file input-file))
  (check-count input-file doc))

(print)
(print "=== Parsing the same text from a string ===")
(with-document (doc (document-parse-string malformed-text))
  (check-count "(string-in-memory)" doc))

(when saw-error (exit 1))
