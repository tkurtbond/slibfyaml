;;;; tests/example-missing-field.scm
;;;;
;;;; Phase 9 port of alibfyaml's own example_missing_field.adb: report
;;;; a MISSING required key three ways -- node-location alone,
;;;; node-path alone, and both together -- to show why a caller might
;;;; want either one independently, or both.
;;;;
;;;; This is a genuinely different case from example-value-error.scm's
;;;; malformed-value one: there, the key exists and has a node with
;;;; its own scalar token, so node-location works directly. Here, the
;;;; key is simply absent -- there is no node/token for it at all, so
;;;; node-location has nothing to report a position for
;;;; (node-has-location? is scalar-only, and there's no scalar to
;;;; ask). node-path has no such problem: the *enclosing mapping's*
;;;; own path is always available regardless of what keys it does or
;;;; doesn't have, so appending the missing key's name to it (e.g.
;;;; "/1" + "/count") gives an exact, unambiguous structural address
;;;; -- something node-location fundamentally cannot do for an absent
;;;; key.
;;;;
;;;; "node-location alone" below approximates a source position by
;;;; using a nearby sibling field's own location instead (here,
;;;; "name", which every entry has) -- clearly labeled as an
;;;; approximation ("near"), since it's the sibling's position, not
;;;; the missing key's own (which doesn't exist to have one). A caller
;;;; who only cares about *which structural element* is broken, not
;;;; what line it's roughly near, can skip this and use node-path
;;;; alone; a caller who wants both prints both. See test-path.scm /
;;;; test-location.scm for these two bindings exercised independently.
;;;;
;;;; Run as: ./example-missing-field [file]  (defaults to
;;;; missing_field.yaml, which has two entries: "alpha" with a count,
;;;; "beta" without one)

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken process-context))

(define input-file
  (let ((args (command-line-arguments)))
    (if (pair? args) (car args) "missing_field.yaml")))

(define saw-error #f)

;; node-location alone: approximate, via a nearby sibling scalar
;; ("name") that every entry is expected to have. Falls back to just
;; "(unknown position)" if even that is missing or has no location of
;; its own (e.g. a freshly-built node).
(define (report-by-location item key)
  (let ((sibling (node-value item "name")))
    (display "[Location]  ")
    (if (and (node-valid? sibling) (node-has-location? sibling))
        (let-values (((line column) (node-location sibling)))
          (display "line ") (display line) (display ", column ") (display column)
          (display " (near \"") (display (node-scalar-value sibling)) (display "\")"))
        (display "(unknown position)"))
    (print ": missing required key \"" key "\"")))

;; node-path alone: exact, always available -- no approximation
;; needed, since item's own node-path exists regardless of which keys
;; it has.
(define (report-by-path item key)
  (print "[Path]      " (node-path item) "/" key
         ": missing required key \"" key "\""))

;; Both together: node-path pinpoints which element, node-location
;; gives a human a line to jump to in an editor -- neither alone gives
;; you both of those.
(define (report-by-both item key)
  (let ((sibling (node-value item "name")))
    (display "[Both]      ") (display (node-path item)) (display "/") (display key) (display " (")
    (if (and (node-valid? sibling) (node-has-location? sibling))
        (let-values (((line column) (node-location sibling)))
          (display "near line ") (display line) (display ", column ") (display column))
        (display "position unknown"))
    (print "): missing required key \"" key "\"")))

(with-document (doc (document-parse-file input-file))
  (let ((root (document-root doc)))
    (let loop ((i 1))
      (when (<= i (node-length root))
        (let ((item (node-item root i)))
          (unless (node-has-key? item "count")
            (set! saw-error #t)
            (report-by-location item "count")
            (report-by-path item "count")
            (report-by-both item "count")))
        (loop (+ i 1))))))

(when saw-error (exit 1))
