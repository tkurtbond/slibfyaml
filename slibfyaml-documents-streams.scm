;;;; slibfyaml-documents-streams.scm
;;;;
;;;; (slibfyaml documents streams), ported from alibfyaml's
;;;; Libfyaml.Documents.Streams: multi-document YAML streaming, built on
;;;; libfyaml's separate streaming-parser API (fy_parser_create +
;;;; repeated fy_parse_load_document calls) rather than the
;;;; single-document fy_document_build_from_string/_file that
;;;; document-parse-string/-file use. Those always mean "parse exactly
;;;; one document" and are unaffected by this module; use this one
;;;; instead for input that may hold more than one "---"-separated
;;;; document.
;;;;
;;;; This module imports (slibfyaml documents) directly (unlike
;;;; (slibfyaml nodes), which deliberately does not) because
;;;; document-stream-next! needs to build a real `document` record --
;;;; there is no dispatching-primitive conflict here the way alibfyaml's
;;;; own Ada child-package split works around (that split is a
;;;; consequence of Ada's tagged-type primitive-operation rules, which
;;;; CHICKEN's module system has no equivalent constraint for).
;;;;
;;;; The central lifetime problem here -- confirmed live by alibfyaml
;;;; with valgrind, ported as a fix rather than rediscovered -- is that
;;;; a document-stream-open-string stream's buffer backs every document
;;;; drawn from it via document-stream-next!, not just the stream's own
;;;; parsing (fy_parser_set_string, like fy_document_build_from_string,
;;;; doesn't copy its input). Destroying the stream while such a
;;;; document is still in use would otherwise free that shared buffer
;;;; out from under it. Fixed the same way alibfyaml fixed it: the
;;;; buffer is a refcounted buffer-ref (see slibfyaml-documents.scm),
;;;; shared -- not copied -- between the stream and every document
;;;; drawn from it, freed only once the last holder releases its share.
;;;; See tests/test-buffer-lifetime.scm for the regression test this
;;;; exists to satisfy.

(module (slibfyaml documents streams)
  (
   document-stream?
   document-stream-open-string
   document-stream-open-file
   document-stream-has-next?
   document-stream-next!
   document-stream-destroy!
   with-document-stream
   )

(import scheme)
(import (chicken base))
(import (chicken foreign))
(import (chicken memory))
(import (chicken gc))
(import (chicken condition))
(import (slibfyaml thin))
(import (slibfyaml documents))
(import (slibfyaml))

(foreign-declare "#include <libfyaml.h>")

;;;; The stream handle itself

(define-record-type document-stream
  (make-document-stream-record handle diag owned-buffer from-string?
                                pending peeked?)
  document-stream?
  (handle document-stream-handle set-document-stream-handle!)
  (diag document-stream-diag set-document-stream-diag!)
  (owned-buffer document-stream-owned-buffer set-document-stream-owned-buffer!)
  (from-string? document-stream-from-string?)
  (pending document-stream-pending set-document-stream-pending!)
  (peeked? document-stream-peeked? set-document-stream-peeked?!))
;; handle/diag: the fy_parser/fy_diag this stream owns. owned-buffer: a
;; buffer-ref (document-stream-open-string's copied text, or
;; document-stream-open-file's copied, NUL-terminated path -- see
;; open-file below for why the path needs the same treatment) or #f.
;; from-string?: which of the two opened this stream, purely to pick
;; Fetch!'s Parse_Error file-override the same way document-parse-
;; string/-file's own Collected_Errors calls already do. pending/
;; peeked?: document-stream-has-next?'s one-ahead read-ahead cache,
;; consumed by document-stream-next! -- libfyaml's streaming API has no
;; side-effect-free way to peek, so Has_Next may actually read the next
;; document ahead of time.

;;;; Diagnostics: swapping Diag after an error
;;;;
;;;; fy_diag_got_error is a sticky flag and fy_diag_errors_iterate's
;;;; collected-errors list is cumulative -- libfyaml never clears
;;;; either on its own. Since a document-stream keeps one diag alive
;;;; for its whole lifetime (unlike document-parse-string/-file's own
;;;; parse-common, which creates and destroys a fresh diag per single-
;;;; document call), replacing it after each error is the only way to
;;;; stop that error from being misreported against a later fetch --
;;;; ported directly from a confirmed alibfyaml bug: every
;;;; has-next?/next! call after a parse error used to raise
;;;; (exn slibfyaml parse) again, quoting the earlier document's now-
;;;; stale message, even once the underlying parser had genuinely
;;;; reached a clean end of input.
;;;;
;;;; This does NOT make the stream able to resume reading further
;;;; documents *past* a malformed one -- confirmed separately (by
;;;; alibfyaml, against the same libfyaml) that its streaming parser
;;;; cannot resync mid-stream after an error (fy_parse_load_document
;;;; keeps returning NULL, and even an explicit fy_parser_reset does
;;;; not restore usable input state). That is a limitation of
;;;; libfyaml's own public streaming API, not something fixable from
;;;; this binding. What this fix does is turn "keeps raising a stale,
;;;; misleading parse error forever" into an honest "has-next? returns
;;;; #f" once the underlying parser has nothing left to give.

(define (replace-diag! stream)
  (let ((new-diag (fy_diag_create #f)))
    (if (not new-diag)
        #f ;; best effort: couldn't allocate a replacement -- leave the
           ;; old (now-stale) diag in place rather than losing
           ;; diagnostics entirely. A later has-next?/next! may
           ;; misreport as before.
        (begin
          (fy_diag_set_collect_errors new-diag #t)
          (if (= 0 (fy_parser_set_diag (document-stream-handle stream) new-diag))
              (begin (fy_diag_destroy (document-stream-diag stream))
                     (set-document-stream-diag! stream new-diag))
              (fy_diag_destroy new-diag))))))

;; Common to has-next?/next!: call fy_parse_load_document once, and
;; turn a NULL result that's actually a parse error (as opposed to a
;; clean end of stream) into (exn slibfyaml parse) -- the two are
;; indistinguishable from the raw NULL alone, only fy_diag_got_error
;; tells them apart. Kept in one place so has-next?'s read-ahead and
;; next!'s own direct fetch (when called without has-next? first)
;; can't drift out of sync on this check.
(define (fetch! stream)
  (let ((fyd (fy_parse_load_document (document-stream-handle stream))))
    (if (and (not fyd) (fy_diag_got_error (document-stream-diag stream)))
        (let-values (((message file line column)
                      (collected-errors (document-stream-diag stream)
                                         (and (document-stream-from-string? stream)
                                              "(string-in-memory)"))))
          (replace-diag! stream)
          (raise-parse-error
           (if (> (string-length message) 0) message "document failed to parse")
           file line column))
        fyd)))

;;;; Open

;; A persistent, NUL-terminated malloc'd copy of s -- unlike
;; document-parse-string's own buffer, this needs the trailing NUL
;; because fy_parser_set_input_file takes a plain `const char *`, not a
;; pointer+length pair.
(define (c-string-copy s)
  (let* ((len (string-length s))
         (buf (c-malloc (+ len 1))))
    (move-memory! s buf len)
    (poke-nul! buf len)
    buf))

(define (document-stream-open-string text)
  (let* ((len (string-length text))
         (buf (c-malloc len)))
    (move-memory! text buf len)
    (handle-exceptions exn
      (begin (c-free buf) (abort exn))
      (open-common buf #t
                   (lambda (fyp) (fy_parser_set_string fyp buf len))
                   "fy_parser_set_string failed"))))
;; text is copied into buf, same buffer-lifetime reasoning as
;; document-parse-string's own text buffer (fy_parser_set_string, like
;; fy_document_build_from_string, doesn't copy its input) -- except
;; here the buffer must stay alive for the whole stream, and every
;; document drawn from it, not just one document-build call. Ownership
;; transfers to a fresh buffer-ref, count one; document-stream-next!
;; gives each document drawn from this stream a shared retain on it.

(define (document-stream-open-file path)
  (let ((buf (c-string-copy path)))
    (handle-exceptions exn
      (begin (c-free buf) (abort exn))
      (open-common buf #f
                   (lambda (fyp) (fy_parser_set_input_file fyp buf))
                   (string-append "fy_parser_set_input_file failed for \"" path "\"")))))
;; Unlike fy_document_build_from_file (a one-shot convenience that
;; reads the file immediately), fy_parser_set_input_file's own header
;; is explicit that it retains the filename pointer for as long as the
;; parser is in use (confirmed independently against the installed
;; header -- see slibfyaml-thin.scm's own comment on this binding; the
;; file is evidently opened lazily, per fy_parse_load_document call).
;; buf is NOT freed here: ownership transfers to a fresh buffer-ref,
;; same as open-string's text buffer above -- though unlike that case,
;; no document ever gets a share of this one (see from-string? below),
;; so this reference count never exceeds one in practice; it's still a
;; buffer-ref rather than a bare pointer, for the same one-release-path
;; uniformity document-parse-file/-string's own owned-buffer already
;; has.

;; Shared by open-string/open-file: create a diag + parser, hand the
;; parser its input via set-input (either fy_parser_set_string or
;; fy_parser_set_input_file, already bound to buf by the caller), and
;; assemble the resulting document-stream -- or clean up and raise
;; (exn slibfyaml parse) on any failure along the way. buf is always
;; already owned by the caller's handle-exceptions wrapper on failure;
;; on success, ownership moves into the returned stream's own
;; buffer-ref.
(define (open-common buf from-string? set-input set-input-failure-message)
  (let ((diag (fy_diag_create #f)))
    (if (not diag)
        (raise-parse-error "fy_diag_create failed" #f #f #f)
        (begin
          (fy_diag_set_collect_errors diag #t)
          (let* ((cfg (make-parse-cfg 0 diag))
                 (fyp (fy_parser_create cfg)))
            (c-free cfg)
            (cond
             ((not fyp)
              (fy_diag_destroy diag)
              (raise-parse-error "fy_parser_create failed" #f #f #f))
             ((not (= 0 (set-input fyp)))
              (fy_parser_destroy fyp)
              (fy_diag_destroy diag)
              (raise-parse-error set-input-failure-message #f #f #f))
             (else
              (let ((stream (make-document-stream-record
                              fyp diag (make-buffer-ref buf) from-string? #f #f)))
                (set-finalizer! stream document-stream-destroy!)
                stream))))))))

;;;; Read

(define (document-stream-has-next? stream)
  (unless (document-stream-peeked? stream)
    (set-document-stream-pending! stream (fetch! stream))
    (set-document-stream-peeked?! stream #t))
  (and (document-stream-pending stream) #t))
;; True if there is at least one more document to read. May itself
;; raise (exn slibfyaml parse), if the read-ahead this performs is what
;; encounters a malformed document.
;;
;; Note: once that happens, a FURTHER call does not raise again (that
;; part is fixed -- see replace-diag!'s own comment) but also does not
;; find any more documents even if the underlying input textually
;; contains more -- it returns #f, same as a genuine clean end of
;; stream. Treat a document-stream as exhausted after its first
;; (exn slibfyaml parse).

(define (document-stream-next! stream)
  (let ((fyd (if (document-stream-peeked? stream)
                 (let ((pending (document-stream-pending stream)))
                   (set-document-stream-peeked?! stream #f)
                   (set-document-stream-pending! stream #f)
                   pending)
                 (fetch! stream))))
    (if (not fyd)
        (error "slibfyaml: document-stream-next!: no document available (check document-stream-has-next? first)")
        (document-wrap fyd (and (document-stream-from-string? stream)
                                 (buffer-ref-retain! (document-stream-owned-buffer stream)))))))
;; Consume and return the next document -- the one document-stream-
;; has-next? found, if it was called first; otherwise this performs its
;; own fetch. Raises (exn slibfyaml parse) if that document fails to
;; parse -- distinct from document-stream-has-next? returning #f (clean
;; end of stream): a parse error partway through the stream is not
;; silently treated as "no more documents".
;;
;; A stream opened via document-stream-open-string backs every document
;; drawn from it with the same zero-copy buffer (see owned-buffer's own
;; comment) -- retained here, rather than leaving the returned document
;; with none, so it survives the stream being destroyed first. A
;; document-stream-open-file-based stream has no such hazard (confirmed
;; live, same as document-parse-file's own case), so its documents get
;; none -- there would be nothing to retain a share of anyway, since
;; open-file's own buffer-ref (the filename) is never shared with a
;; document in the first place.

;;;; Destruction

(define (document-stream-destroy! stream)
  (when (document-stream-handle stream)
    (fy_parser_destroy (document-stream-handle stream))
    (set-document-stream-handle! stream #f))
  (when (document-stream-diag stream)
    (fy_diag_destroy (document-stream-diag stream))
    (set-document-stream-diag! stream #f))
  (let ((buf (document-stream-owned-buffer stream)))
    (when buf
      (buffer-ref-release! buf)
      (set-document-stream-owned-buffer! stream #f))))
;; Idempotent, same discipline as document-destroy! -- each of the
;; three fields checked here is set back to #f (or, for owned-buffer,
;; released) immediately after acting on it, so a second call (whether
;; explicit, or the GC finalizer backstop firing after an explicit call
;; already ran) finds nothing left to do.
;;
;; buffer-ref-release! only frees the buffer once every holder has
;; released its own share: if a document drawn from this stream via
;; document-stream-next! still holds a retained copy (the
;; document-stream-open-string case), the underlying buffer isn't
;; actually freed until that document is destroyed too -- see
;; tests/test-buffer-lifetime.scm.
;;
;; No liveness box / use-after-free tracking on document-stream itself
;; the way document/node have -- alibfyaml's own Document_Stream has no
;; equivalent contract on its own operations either (only Document/Node
;; are documented as tied to a lifetime chain), and nothing currently
;; needs one: unlike a node, no other object holds a reference to a
;; document-stream that would need invalidating if it's destroyed out
;; from under it.

(define-syntax with-document-stream
  (syntax-rules ()
    ((_ (stream expr) body ...)
     (let ((stream expr))
       (dynamic-wind
        (lambda () #f)
        (lambda () body ...)
        (lambda () (document-stream-destroy! stream)))))))
;; Recommended idiom for anything that isn't itself long-lived, same
;; shape as (slibfyaml documents)'s own with-document -- not part of
;; alibfyaml's own API (Ada's Document_Stream gets this for free from
;; scope-exit Finalize), added here for the same reason with-document
;; was: CHICKEN has no deterministic destructors, so deterministic
;; cleanup needs an explicit combinator instead of being assumed.

) ;; module
