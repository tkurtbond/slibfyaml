;;;; tests/test-anchors.scm
;;;;
;;;; Phase 5 regression test for anchors/aliases/merge keys/tags:
;;;; resolve-anchors? on document-parse-file (default #t vs explicit
;;;; #f), node-alias?/node-tag on the raw unresolved tree,
;;;; document-resolve! called explicitly, and (exn slibfyaml resolve)
;;;; on a genuine merge-key reference loop -- an slibfyaml port of
;;;; alibfyaml's own test_anchors.adb, using its anchors.yaml/
;;;; anchors_cycle.yaml fixtures directly for comparability.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml nodes))
(import (chicken condition))

;; -----------------------------------------------------------------
;; Default (resolve-anchors? #t): the alias and the merge key are both
;; resolved as part of parsing, with no separate call needed.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "anchors.yaml"))
  (let ((same (node-by-path (document-root doc) "/same")))
    (check "default parse: alias node is no longer node-alias?"
           (not (node-alias? same)))
    (check "default parse: alias resolves to the anchored mapping"
           (and (node-mapping? same)
                (string=? "1" (node-scalar-value (node-value same "x")))
                (string=? "2" (node-scalar-value (node-value same "y")))))
    (check "default parse: merge key's own pairs are reachable"
           (and (string=? "1" (node-scalar-value (node-by-path (document-root doc) "/derived/x")))
                (string=? "2" (node-scalar-value (node-by-path (document-root doc) "/derived/y")))))
    (check "default parse: merge target's own pairs are kept too"
           (string=? "3" (node-scalar-value (node-by-path (document-root doc) "/derived/z"))))))

;; -----------------------------------------------------------------
;; resolve-anchors? #f: the raw, unresolved tree -- confirmed here
;; rather than just assumed, so a future change to the default can't
;; silently break the case it exists to support (inspecting anchors/
;; aliases themselves via node-alias?/node-tag before resolving).
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "anchors.yaml" #f))
  (let ((same (node-by-path (document-root doc) "/same")))
    (check "unresolved parse: alias node reports node-alias?"
           (node-alias? same))
    (check "unresolved parse: alias's own text is just the anchor name"
           (string=? "b" (node-scalar-value same)))
    (check "unresolved parse: merge key's pairs are not yet reachable"
           (not (node-valid? (node-by-path (document-root doc) "/derived/x"))))

    (document-resolve! doc)
    (check "after explicit document-resolve!: alias is no longer node-alias?"
           (not (node-alias? same)))
    (check "after explicit document-resolve!: alias resolves to the anchored mapping"
           (and (node-mapping? same) (node-valid? (node-value same "x"))))
    (check "after explicit document-resolve!: merge key's pairs are now reachable"
           (string=? "1" (node-scalar-value (node-by-path (document-root doc) "/derived/x"))))))

;; -----------------------------------------------------------------
;; Explicit tags: node-tag returns the raw tag text verbatim, or ""
;; when a node has none.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "anchors.yaml"))
  (check "explicit tag: node-tag returns the raw tag text"
         (string=? "!mytag" (node-tag (node-by-path (document-root doc) "/tagged"))))
  (check "no explicit tag: node-tag returns \"\""
         (string=? "" (node-tag (node-by-path (document-root doc) "/untagged")))))

;; -----------------------------------------------------------------
;; (exn slibfyaml resolve): a merge key that references its own
;; anchor (a: &a {<<: *a, x: 1}) is a genuine reference loop, not
;; something document-resolve! can complete. libfyaml detects this
;; itself and returns a clean failure status rather than hanging --
;; confirmed by alibfyaml against this same fixture.
;;
;; Note (not a defect in this binding, carried forward from
;; alibfyaml's own finding): resolving this specific fixture leaks a
;; small, fixed amount of memory entirely inside libfyaml's own
;; ref-loop-detection diagnostic path (fy_document_resolve ->
;; fy_check_ref_loop -> fy_document_diag_report), confirmed there with
;; valgrind against the same libfyaml build this binding links -- so a
;; valgrind run against this test may show that leak too; it isn't
;; something to chase down here.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "anchors_cycle.yaml" #f))
  (check "document-resolve! on a merge-key reference loop raises (exn slibfyaml resolve)"
         (condition-case (begin (document-resolve! doc) #f)
           ((exn slibfyaml resolve) #t)
           (e () #f))))

(check-summary-and-exit)
