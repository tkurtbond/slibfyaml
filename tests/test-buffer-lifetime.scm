;;;; tests/test-buffer-lifetime.scm
;;;;
;;;; Phase 6 regression test, split out from test-streams.scm per
;;;; PLAN.md's own explicit call for a dedicated, unmissable file
;;;; covering exactly the scenario alibfyaml found broken (confirmed
;;;; live with valgrind, before it was fixed there): a document drawn
;;;; from a string-backed document-stream must remain correctly
;;;; readable even after that stream is destroyed -- the stream's
;;;; buffer backs the document's own scalars too (fy_parser_set_string
;;;; doesn't copy its input), not just the stream's own parsing.
;;;;
;;;; Ported from alibfyaml's own test_streams.adb's
;;;; Doc_Outliving_Its_Stream case, adapted for CHICKEN's explicit (not
;;;; scope-exit) destruction: Ada's version relies on the stream simply
;;;; going out of scope at the end of a function, triggering Finalize
;;;; automatically; here the stream is destroyed explicitly instead,
;;;; since that's the only deterministic way (rather than hoping a GC
;;;; happens at the right moment) to force the exact ordering this test
;;;; needs to prove safe -- see PLAN.md's "Document ownership: no RAII,
;;;; so what replaces it?" for why CHICKEN needs this to be explicit at
;;;; all.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml documents streams))
(import (slibfyaml nodes))

(define (doc-outliving-its-stream)
  (let* ((stream (document-stream-open-string "name: widget"))
         (doc (document-stream-next! stream)))
    (document-stream-destroy! stream)
    doc))

(let ((doc (doc-outliving-its-stream)))
  (check "a document drawn from document-stream-open-string reads correctly after its document-stream is destroyed"
         (string=? "widget" (node-string-value (document-root doc) "name")))
  (document-destroy! doc))

(check-summary-and-exit)
