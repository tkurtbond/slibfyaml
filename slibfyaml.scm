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

) ;; module
