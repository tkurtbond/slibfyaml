;;;; tests/test-streams.scm
;;;;
;;;; Phase 6 regression test for multi-document YAML streaming:
;;;; document-parse-file only ever seeing the first document,
;;;; document-stream-open-file/-open-string reading every document in
;;;; order, the empty-stream and single-document-stream boundaries, and
;;;; a mid-stream parse error raising (exn slibfyaml parse) rather than
;;;; looking like a clean end of stream -- with a further call after
;;;; that error reporting a clean end rather than raising a second,
;;;; stale error. An slibfyaml port of most of alibfyaml's own
;;;; test_streams.adb (its "document outlives its stream" scenario has
;;;; its own dedicated file here, tests/test-buffer-lifetime.scm, per
;;;; PLAN.md's explicit call for that), using its streams.yaml fixture
;;;; directly for comparability.

(include "check.scm")

(import (slibfyaml documents))
(import (slibfyaml documents streams))
(import (slibfyaml nodes))
(import (chicken condition))

(define (string-prefix? prefix s)
  (and (>= (string-length s) (string-length prefix))
       (string=? prefix (substring s 0 (string-length prefix)))))

;; -----------------------------------------------------------------
;; document-parse-file only ever sees the first document of
;; streams.yaml.
;; -----------------------------------------------------------------
(with-document (doc (document-parse-file "streams.yaml"))
  (check "document-parse-file sees only the first document"
         (string=? "first" (node-string-value (document-root doc) "name"))))

;; -----------------------------------------------------------------
;; document-stream-open-file reads all three, in order, each a real,
;; independently usable document.
;; -----------------------------------------------------------------
(let ((expected-name (lambda (n) (case n ((1) "first") ((2) "second") ((3) "third") (else "?"))))
      (count 0))
  (with-document-stream (stream (document-stream-open-file "streams.yaml"))
    (let loop ()
      (when (document-stream-has-next? stream)
        (set! count (+ count 1))
        (with-document (doc (document-stream-next! stream))
          (check (string-append "document-stream-open-file document " (number->string count) " name")
                 (string=? (expected-name count) (node-string-value (document-root doc) "name")))
          (check (string-append "document-stream-open-file document " (number->string count) " value")
                 (= count (node-integer-value (document-root doc) "value"))))
        (loop)))
    (check "document-stream-open-file yielded exactly 3 documents" (= 3 count))
    (check "document-stream-has-next? stays #f once exhausted"
           (not (document-stream-has-next? stream)))))

;; -----------------------------------------------------------------
;; Same thing via document-stream-open-string, to exercise the
;; owned-buffer path.
;; -----------------------------------------------------------------
(let ((text "---\nname: a\n---\nname: b\n")
      (count 0))
  (with-document-stream (stream (document-stream-open-string text))
    (let loop ()
      (when (document-stream-has-next? stream)
        (set! count (+ count 1))
        (with-document (doc (document-stream-next! stream))
          (check (string-append "document-stream-open-string document " (number->string count))
                 (string=? (if (= count 1) "a" "b") (node-string-value (document-root doc) "name"))))
        (loop)))
    (check "document-stream-open-string yielded exactly 2 documents" (= 2 count))))

;; -----------------------------------------------------------------
;; Boundary: an empty stream (no documents at all) reports
;; document-stream-has-next? = #f immediately, not an error.
;; -----------------------------------------------------------------
(with-document-stream (stream (document-stream-open-string ""))
  (check "document-stream-open-string (\"\") has no documents"
         (not (document-stream-has-next? stream))))

;; -----------------------------------------------------------------
;; Boundary: a stream containing exactly one document behaves the same
;; as document-parse-string would for that one document, then reports
;; a clean end.
;; -----------------------------------------------------------------
(let ((count 0))
  (with-document-stream (stream (document-stream-open-string "---\nname: only\n"))
    (let loop ()
      (when (document-stream-has-next? stream)
        (set! count (+ count 1))
        (with-document (doc (document-stream-next! stream))
          (check (string-append "single-document stream: document " (number->string count) " name")
                 (string=? "only" (node-string-value (document-root doc) "name"))))
        (loop)))
    (check "single-document stream yielded exactly 1 document" (= 1 count))))

;; -----------------------------------------------------------------
;; A parse error partway through a stream must raise (exn slibfyaml
;; parse), not look like a clean end of stream -- and calling
;; document-stream-has-next? *again* afterward must not raise a
;; second, stale parse error quoting the same old message. It should
;; instead report a clean end of stream: libfyaml's streaming parser
;; cannot resync past a malformed document to reach further ones in
;; the same stream. A third, well-formed document is included below
;; specifically to prove it's genuinely unreachable after the error,
;; not just untested.
;; -----------------------------------------------------------------
(let ((text "---\nname: ok\n---\n[unterminated flow sequence\n---\nname: third\n"))
  (with-document-stream (stream (document-stream-open-string text))
    (define saw-first #f)
    (define raised-parse-error #f)
    (define reports-as-string #f)
    (when (document-stream-has-next? stream)
      (with-document (doc (document-stream-next! stream))
        (set! saw-first (string=? "ok" (node-string-value (document-root doc) "name")))))
    (condition-case
     (when (document-stream-has-next? stream)
       (document-destroy! (document-stream-next! stream)))
     (e (exn slibfyaml parse)
        (set! raised-parse-error #t)
        (set! reports-as-string
              (string-prefix? "(string-in-memory):"
                               (get-condition-property e 'exn 'message))))
     (e () #f))
    (check "first document of the bad stream still parsed fine" saw-first)
    (check "malformed second document -> (exn slibfyaml parse), not silent end-of-stream"
           raised-parse-error)
    (check "document-stream-open-string's parse error reports \"(string-in-memory)\", not libfyaml's own synthetic memory-address label"
           reports-as-string)
    (check "document-stream-has-next? after the error reports a clean end, not another (stale) parse error"
           (not (document-stream-has-next? stream)))))

(check-summary-and-exit)
