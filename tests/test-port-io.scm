;;;; tests/test-port-io.scm
;;;;
;;;; Phase 10 regression test for document-parse-port and
;;;; document-write-to-port! -- no alibfyaml source to port (Ada's own
;;;; Text_IO-based parse is GNAT-specific, see PLAN.md's Phase 9/10
;;;; writeups), so this is this egg's own test, in the same
;;;; ok/FAIL style as everything else.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))
(import (chicken io))

;; -----------------------------------------------------------------
;; document-parse-port on a string port reads identically to
;; document-parse-string on the same text.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-port (open-input-string "name: widget\ncount: 42\n")))
  (check "document-parse-port on a string port: name is widget"
         (string=? "widget" (node-scalar-value (node-value (document-root doc) "name"))))
  (check "document-parse-port on a string port: count is 42"
         (string=? "42" (node-scalar-value (node-value (document-root doc) "count")))))

;; -----------------------------------------------------------------
;; document-parse-port on a real open file port reads the same as
;; document-parse-file on the same path.
;; -----------------------------------------------------------------
(with-document (doc-file (document-parse-file "config.yaml"))
  (with-document (doc-port (call-with-input-file "config.yaml" document-parse-port))
    (check "document-parse-port on a file port matches document-parse-file: server.host"
           (string=? (node-scalar-value (node-value (node-value (document-root doc-file) "server") "host"))
                     (node-scalar-value (node-value (node-value (document-root doc-port) "server") "host"))))))

;; -----------------------------------------------------------------
;; A malformed port raises (exn slibfyaml parse), reporting file
;; "(port)" -- distinct from document-parse-string's own
;; "(string-in-memory)" -- so a caller can tell the two input sources
;; apart in a caught condition's own 'file property.
;; -----------------------------------------------------------------
(let ((raised #f) (reports-as-port #f))
  (condition-case
   (begin (document-parse-port (open-input-string "bad: [1, 2")) #f)
   (e (exn slibfyaml parse)
      (set! raised #t)
      (set! reports-as-port (string=? "(port)" (get-condition-property e 'parse 'file))))
   (e () #f))
  (check "document-parse-port on malformed input raises (exn slibfyaml parse), not a process abort"
         raised)
  (check "document-parse-port's parse error reports \"(port)\", not \"(string-in-memory)\""
         reports-as-port))

;; -----------------------------------------------------------------
;; document-write-to-port! with default flags writes the same text
;; document->yaml-string returns.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "name: widget\ntags: [alpha, beta]\n"))
  (let ((expected (document->yaml-string doc))
        (out (open-output-string)))
    (document-write-to-port! doc out)
    (check "document-write-to-port! (default flags) matches document->yaml-string"
           (string=? expected (get-output-string out))))

  ;; -- a non-default emit flag reaches document-write-to-port! too,
  ;; and the result still round-trips through document-parse-port --
  (let ((out (open-output-string)))
    (document-write-to-port! doc out emit-mode-json)
    (let ((json-text (get-output-string out)))
      (check "document-write-to-port! with emit-mode-json matches document->yaml-string with the same flags"
             (string=? (document->yaml-string doc emit-mode-json) json-text))
      (with-document (doc2 (document-parse-port (open-input-string json-text)))
        (check "document-write-to-port!'s emit-mode-json output round-trips: name is widget"
               (string=? "widget" (node-scalar-value (node-value (document-root doc2) "name"))))))))

(check-summary-and-exit)
