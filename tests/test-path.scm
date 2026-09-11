;;;; tests/test-path.scm
;;;;
;;;; Phase 9 port of alibfyaml's own test_path.adb: exercises
;;;; node-path, the inverse of node-by-path -- given a node, return
;;;; its own structural address relative to the document root (e.g.
;;;; "/company/departments/0/teams/1"), in the same syntax
;;;; node-by-path already accepts as input.
;;;;
;;;; Deliberately independent of node-location/node-has-location?
;;;; (test-location.scm): node-path works on a node of ANY kind --
;;;; mapping and sequence nodes included, not just scalars -- since
;;;; it's purely structural, unlike a source location, which needs a
;;;; scalar token to hang a line/column off of. A caller with both
;;;; bindings available can use either one alone or both together;
;;;; nothing here requires the other. See tests/example-missing-field.
;;;; scm for a worked "use both at once" case (node-location
;;;; approximates a position via a nearby scalar sibling, node-path
;;;; pinpoints the exact structural location of a genuinely missing
;;;; key that has no node/token of its own to report a location for).
;;;;
;;;; All path strings below were read out live against navigate.yaml
;;;; (not hand-derived from the header), including the document root's
;;;; own case -- see slibfyaml-nodes.scm's own comment on node-path and
;;;; slibfyaml-thin.scm's fy_node_get_path for why that returns the
;;;; real string "/" rather than "", despite what the C header claims
;;;; ("NULL if fyn is the root").

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))

(define (check-path label n expected)
  (check (string-append label ": node-path = \"" expected "\"")
         (string=? expected (node-path n))))

(with-document (doc (document-parse-file "navigate.yaml"))
  (let ((root (document-root doc)))

    ;; -----------------------------------------------------------
    ;; The document root itself: "/", not "" -- confirmed live,
    ;; despite the C header's own claim that fy_node_get_path returns
    ;; NULL for the root (slibfyaml-thin.scm's fy_node_get_path
    ;; comment).
    ;; -----------------------------------------------------------
    (check-path "root" root "/")

    ;; -----------------------------------------------------------
    ;; A top-level scalar field.
    ;; -----------------------------------------------------------
    (check-path "name" (node-by-path root "/name") "/name")

    ;; -----------------------------------------------------------
    ;; A sequence element (0-indexed, matching node-by-path's own
    ;; syntax).
    ;; -----------------------------------------------------------
    (check-path "tags/0" (node-by-path root "/tags/0") "/tags/0")

    ;; -----------------------------------------------------------
    ;; A mapping node, not a scalar -- node-path works here;
    ;; node-location (test-location.scm) does not, since a mapping
    ;; node has no scalar token of its own to report a source
    ;; position for. This is the concrete case node-path exists to
    ;; cover that node-location can't.
    ;; -----------------------------------------------------------
    (let ((server (node-by-path root "/server")))
      (check "server: node-mapping?" (node-mapping? server))
      (check-path "server" server "/server"))

    ;; -----------------------------------------------------------
    ;; Four levels of nesting (sequence/mapping/sequence/mapping),
    ;; same fixture path test-navigate.scm's own deep-access case
    ;; uses -- confirms node-path round-trips through real nesting,
    ;; not just one level.
    ;; -----------------------------------------------------------
    (check-path "company/departments/0/teams/1"
                (node-by-path root "/company/departments/0/teams/1")
                "/company/departments/0/teams/1")

    ;; -----------------------------------------------------------
    ;; A field inside one element of a sequence-of-mappings.
    ;; -----------------------------------------------------------
    (check-path "endpoints/1/name"
                (node-by-path root "/endpoints/1/name")
                "/endpoints/1/name")

    ;; -----------------------------------------------------------
    ;; Round-trip: node-by-path (node-path n) = n, for a node reached
    ;; two different ways (chained node-value/node-item vs.
    ;; node-by-path) -- confirms node-path's output is genuinely
    ;; usable as node-by-path input, not just a similar-looking
    ;; string.
    ;; -----------------------------------------------------------
    (let* ((lead (node-value
                  (node-item
                   (node-value
                    (node-item (node-value (node-value root "company") "departments") 1)
                    "teams")
                   1)
                  "lead"))
           (round-tripped (node-by-path root (node-path lead))))
      (check "round-trip node-by-path (node-path n) = n"
             (string=? (node-scalar-value lead) (node-scalar-value round-tripped))))))

(check-summary-and-exit)
