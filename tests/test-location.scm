;;;; tests/test-location.scm
;;;;
;;;; Phase 8 regression test for node-has-location?/node-location, an
;;;; slibfyaml port of alibfyaml's own test_location.adb, using its
;;;; location.yaml fixture directly (and anchors.yaml, already used by
;;;; test-anchors.scm, for the alias case) for comparability. All
;;;; line/column values below were read out live against these exact
;;;; fixtures, the same way test_location.adb's own header notes for
;;;; its own -- not hand-counted.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))

(define (check-location label n line column)
  (check (string-append label ": node-has-location?") (node-has-location? n))
  (when (node-has-location? n)
    (let-values (((l c) (node-location n)))
      (check (string-append label ": line") (= l line))
      (check (string-append label ": column") (= c column)))))

;; -----------------------------------------------------------------
;; location.yaml:
;;   1  name: widget
;;   2  count: 42
;;   3  empty:
;; 1-indexed positions of each key's own scalar value.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "location.yaml"))
  (check-location "name"  (node-by-path (document-root doc) "/name")  1 7)
  (check-location "count" (node-by-path (document-root doc) "/count") 2 8)
  ;; An empty/omitted scalar ("key:" with nothing after it) still has a
  ;; real, zero-width location -- not a missing one.
  (check-location "empty" (node-by-path (document-root doc) "/empty") 3 6))

;; -----------------------------------------------------------------
;; anchors.yaml's alias node (already used by test-anchors.scm):
;; "same: *b" on line 7. The location is of the anchor-name text ("b",
;; column 8) -- not the "*" sigil at column 7 -- confirmed live, not
;; assumed from the token's start.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "anchors.yaml" #f))
  (let ((same (node-by-path (document-root doc) "/same")))
    (check "alias node: node-alias?" (node-alias? same))
    (check-location "alias node" same 7 8)))

;; -----------------------------------------------------------------
;; A freshly-built (not parsed) scalar node: node-has-location? is #t
;; -- its token carries a synthetic all-zero mark rather than a NULL
;; one, confirmed live -- but node-location is the fixed (1, 1), not a
;; real position in any source text. Documented on node-has-location?'s
;; own comment; pinned down here so a future change to
;; document-create-scalar's underlying libfyaml call can't silently
;; start returning something else unnoticed.
;;
;; Attached via document-set-root! (rather than left dangling) so the
;; document's own destroy actually owns and frees it -- a
;; document-create-scalar node never attached anywhere is a genuine, if
;; unsurprising, leak (confirmed live with valgrind while writing
;; test_location.adb's own equivalent case) -- nothing in the tree
;; references it, so nothing frees it either.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-string "{}"))
  (let ((fresh (document-create-scalar doc "x")))
    (check-location "freshly-built scalar" fresh 1 1)
    (document-set-root! doc fresh)))

(check-summary-and-exit)
