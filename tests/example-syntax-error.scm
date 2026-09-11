;;;; tests/example-syntax-error.scm
;;;;
;;;; Phase 9 port of alibfyaml's own example_syntax_error.adb: parse a
;;;; YAML file that fails to parse at all (a syntax error -- bad
;;;; indentation, an unclosed bracket, etc.) and report it in gcc's
;;;; own diagnostic format: "file:line:column: error: message".
;;;;
;;;; There is no document/tree/node to query here -- the error is from
;;;; the parser itself, before any tree exists -- so this uses the
;;;; (exn slibfyaml parse) condition's own 'exn 'message property
;;;; directly, not node-location (which needs an existing node from a
;;;; successfully-parsed tree; see example-value-error.scm for that
;;;; case instead). The message is already exactly gcc format, one
;;;; line per collected libfyaml error (see slibfyaml-documents.scm's
;;;; collected-errors).
;;;;
;;;; Shows the same malformed YAML text parsed two ways -- from a file
;;;; (document-parse-file) and from an in-memory string
;;;; (document-parse-string) -- to make the one real difference
;;;; between them obvious: the "file" field. From a file it's the real
;;;; path; from a string, libfyaml has no real filename to report and
;;;; (confirmed live) falls back to a synthetic, run-varying
;;;; "<memory-@ADDR-ADDR>" label -- which document-parse-string
;;;; overrides to a fixed "(string-in-memory)" instead. Everything
;;;; else about the message (line, column, the description) is
;;;; identical either way, since both parse the exact same bytes.
;;;;
;;;; Run as: ./example-syntax-error [file]  (defaults to malformed.yaml)

(import (slibfyaml documents))
(import (chicken condition))
(import (chicken process-context))

(define input-file
  (let ((args (command-line-arguments)))
    (if (pair? args) (car args) "malformed.yaml")))

;; Matches malformed.yaml's own content exactly, so both cases below
;; report the same line/column for the same underlying error -- only
;; the "file" field differs.
(define malformed-text "name: widget\nbad: [1, 2\n")

(define saw-error #f)

(print "=== Parsing from a file ===")
(condition-case
 (begin
   (document-destroy! (document-parse-file input-file))
   (print input-file " parsed with no errors."))
 (e (exn slibfyaml parse)
    (print (get-condition-property e 'exn 'message))
    (set! saw-error #t)))

(print)
(print "=== Parsing the same text from a string ===")
(condition-case
 (begin
   (document-destroy! (document-parse-string malformed-text))
   (print "parsed with no errors."))
 (e (exn slibfyaml parse)
    (print (get-condition-property e 'exn 'message))
    (set! saw-error #t)))

(when saw-error (exit 1))
