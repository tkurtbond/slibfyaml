;;;; tests/test-thin.scm
;;;;
;;;; Phase 1 regression test for (slibfyaml thin): every foreign-lambda
;;;; signature actually gets exercised against real libfyaml, not just
;;;; type-checked at compile time. Confirmed by hand before this file
;;;; existed (parse "hello: world", walk the tree, read the scalar back
;;;; byte-for-byte, destroy) under both CHICKEN 5.4.0 and 6.0.0, with a
;;;; valgrind run showing zero leaks/errors -- see PLAN.md's "Target
;;;; CHICKEN version(s)" section. This file makes that check permanent
;;;; instead of a one-off.
;;;;
;;;; ok/FAIL convention matches alibfyaml's own test style (see its
;;;; AGENTS.md): each check prints "ok   - <label>" or "FAIL - <label>",
;;;; and the run ends with "All checks passed." or "<N> check(s) failed."
;;;; -- kept inline here rather than factored into a shared helper, since
;;;; this is still the only test file; factor out once a second one needs
;;;; the same few lines (see PLAN.md's Testing plan for what's coming:
;;;; test-scalars, test-navigate, ...).

(import (slibfyaml thin))
(import (chicken foreign))
(import (chicken memory))
(import (chicken process-context))

(define failures 0)

(define (check label ok?)
  (if ok?
      (print "ok   - " label)
      (begin
        (print "FAIL - " label)
        (set! failures (+ failures 1)))))

;; A malloc'd, memcpy'd C buffer -- not a transient c-string -- standing
;; in here for what (slibfyaml documents)'s document-parse-string will
;; do for real in Phase 2 (see PLAN.md's "buffer-lifetime problem"
;; section): fy_document_build_from_string keeps scalars as zero-copy
;; spans into whatever buffer it's given, for the life of the document,
;; so that buffer must outlive the document, not just the call.
(define (c-malloc n) ((foreign-lambda c-pointer "malloc" size_t) n))

(define yaml-text "hello: world\n")
(define buf (c-malloc (string-length yaml-text)))
(move-memory! yaml-text buf (string-length yaml-text))

(define doc (fy_document_build_from_string #f buf (string-length yaml-text)))
(check "fy_document_build_from_string returns a non-null document"
       (and doc (pointer? doc)))

(define root (fy_document_root doc))
(check "fy_document_root returns a non-null node"
       (and root (pointer? root)))

;; enum fy_node_type: FYNT_SCALAR=0, FYNT_SEQUENCE=1, FYNT_MAPPING=2 --
;; hard-coded here deliberately, not looked up via foreign-value: this
;; is (slibfyaml thin) exercising its own raw functions before (slibfyaml
;; nodes) exists to map the enum to a Scheme symbol; that mapping (and
;; the foreign-value lookup backing it) belongs to nodes.scm in Phase 2.
(check "root node is a mapping" (= 2 (fy_node_get_type root)))
(check "mapping has 1 item" (= 1 (fy_node_mapping_item_count root)))

(define value (fy_node_mapping_lookup_value_by_string root "hello" 5))
(check "mapping-lookup-by-string finds the key"
       (and value (pointer? value)))
(check "value node is a scalar" (= 0 (fy_node_get_type value)))

(define get-size_t (foreign-lambda* size_t ((c-pointer p)) "C_return(*(size_t *)p);"))
(define lenp (c-malloc (foreign-type-size "size_t")))
(define scalar-ptr (fy_node_get_scalar value lenp))
(define scalar-len (get-size_t lenp))
(define scalar-text (make-string scalar-len))
(move-memory! scalar-ptr scalar-text scalar-len)
(check "scalar value round-trips as \"world\"" (string=? "world" scalar-text))

(fy_document_destroy doc)
(check "fy_document_destroy runs without crashing" #t)

(print)
(if (= 0 failures)
    (print "All checks passed.")
    (print failures " check(s) failed."))
(exit (if (= 0 failures) 0 1))
