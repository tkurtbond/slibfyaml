;;;; slibfyaml.scm
;;;;
;;;; (slibfyaml): condition types, ported from alibfyaml's top-level
;;;; Libfyaml package (which holds only its five exception declarations,
;;;; nothing else -- this module mirrors that scope exactly, plus the two
;;;; CHICKEN-specific conditions PLAN.md's Memory model section decided
;;;; on that have no Ada equivalent).
;;;;
;;;; Every condition here is a CHICKEN composite condition carrying three
;;;; kinds -- 'exn, 'slibfyaml, and one specific to the failure (e.g.
;;;; 'parse) -- so `(condition-case ... ((exn slibfyaml parse) ...))`
;;;; works the ordinary way, matching the condition-tagging convention
;;;; the existing `yaml` egg already uses for its own parse exception.
;;;; Only the specific-kind's own properties (e.g. parse's 'file/'line/
;;;; 'column) are exposed as accessors here beyond 'message -- callers
;;;; that want them programmatically use `get-condition-property`
;;;; against the condition object directly.

(module (slibfyaml)
  (
   raise-parse-error
   raise-use-after-free
   raise-missing-key
   raise-data-error
   raise-emit-error
   raise-consumed
   raise-resolve-error
   )

(import scheme)
(import (chicken condition))

(define (slibfyaml-condition kind message . properties)
  (make-composite-condition
   (make-property-condition 'exn 'message message 'arguments '())
   (make-property-condition 'slibfyaml)
   (apply make-property-condition kind properties)))

(define (raise-parse-error message file line column)
  (abort (slibfyaml-condition 'parse message
                               'file file 'line line 'column column)))
;; message is the full, already gcc-style-formatted diagnostic text
;; (one "file:line:column: error: ..." line per collected libfyaml
;; error, see (slibfyaml documents)'s Collected_Errors-equivalent);
;; file/line/column are the *first* collected error's location,
;; exposed as structured fields for a caller that wants to act on the
;; failure programmatically rather than re-parsing the message string
;; -- same rationale as the existing `yaml` egg's own parse exception.

(define (raise-use-after-free message)
  (abort (slibfyaml-condition 'use-after-free message)))
;; Raised by a (slibfyaml nodes) accessor called on a node whose owning
;; document has been destroyed. Has no Ada equivalent -- alibfyaml's
;; contract for this is documentation-only (see PLAN.md's "Node
;; validity after its Document is gone" and the note added to
;; alibfyaml's own libfyaml-nodes.ads).

(define (raise-missing-key key path)
  (abort (slibfyaml-condition 'missing-key
                               (string-append "missing required key \"" key
                                              "\" at " path)
                               'path path)))
;; Raised by node-required (and, through it, every mapping-collapsed
;; typed accessor's required form) when Key is absent from Map. Carries
;; 'path -- (node-path map) -- as a structured field in addition to
;; folding it into the message text, per PLAN.md's "Location and Path"
;; section: alibfyaml's own Missing_Key carries only a bare message,
;; this goes further since CHICKEN conditions make it cheap to.

(define (raise-data-error message path)
  (abort (slibfyaml-condition 'data message 'path path)))
;; Raised by every typed scalar accessor (node-integer-value and
;; friends) for a shape or grammar mismatch -- non-scalar value, text
;; that doesn't match the target type's grammar, or (for float) a
;; literal that overflows a double to infinity. message is the same
;; bare diagnostic text alibfyaml's own Data_Error carries (e.g. "not a
;; valid integer: \"banana\""); 'path -- (node-path n), always
;; available -- is attached as a structured field on top, same
;; rationale as raise-missing-key above. 'line/'column (from
;; node-location, when available) are deferred to Phase 8, which is
;; where node-location/node-has-location? are introduced.

(define (raise-emit-error message)
  (abort (slibfyaml-condition 'emit message)))
;; Raised by document->yaml-string/document-write-to-file! when
;; fy_emit_document_to_string/_file fails. Same as alibfyaml's
;; Emit_Error.

(define (raise-consumed message)
  (abort (slibfyaml-condition 'consumed message)))
;; Raised by a (slibfyaml nodes) accessor called on a node already
;; handed to document-insert-at!, which unconditionally consumes its
;; node argument (see slibfyaml-documents.scm's own comment on
;; document-insert-at! for why, ported from alibfyaml's own confirmed
;; Insert_At use-after-free bug). Has no Ada equivalent as a raised
;; condition -- Ada catches the equivalent mistake at compile time via
;; a `-gnata` precondition on a Node already nulled to Null_Node
;; instead, per PLAN.md's "Node validity after its Document is gone".
;; Distinct from use-after-free above: "your document is gone" and
;; "you already handed this specific node to document-insert-at!" are
;; different mistakes with different fixes.

(define (raise-resolve-error message)
  (abort (slibfyaml-condition 'resolve message)))
;; Raised by document-resolve! when fy_document_resolve fails -- e.g. a
;; merge-key reference loop, which libfyaml detects and reports as a
;; clean failure status rather than hanging. Same as alibfyaml's
;; Resolve_Error.

) ;; module
