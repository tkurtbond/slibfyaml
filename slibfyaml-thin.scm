;;;; slibfyaml-thin.scm
;;;;
;;;; Libfyaml.Thin, adapted: low-level 1:1 foreign-lambda imports over
;;;; libfyaml's exported C symbols. No ownership or error-checking policy
;;;; imposed here -- build the idiomatic API in (slibfyaml documents) /
;;;; (slibfyaml nodes) on top of this module rather than using it directly.
;;;;
;;;; Only the non-variadic core (parser/document/node/emitter/diag) surface
;;;; is covered, mirroring alibfyaml's src/libfyaml-thin.ads scope exactly
;;;; (see PLAN.md's "C function surface" section for the full rationale and
;;;; the confirmed-present-in-header check every name below was verified
;;;; against). libfyaml also has a generics layer (fy_generic, built on
;;;; C11 _Generic/variadic macros with no C-callable equivalent) and a
;;;; reflection layer (typed C-struct serdes via libclang/packed metadata),
;;;; both out of scope here for the same reasons as alibfyaml.
;;;;
;;;; A few functions here take a heap-allocated `char *`/`const char *`
;;;; result that either isn't NUL-terminated at the intended length (a
;;;; zero-copy span back into source text -- fy_node_get_scalar,
;;;; fy_node_get_tag) or must be freed by the caller (fy_node_get_path,
;;;; fy_emit_document_to_string). Those are typed `c-pointer` here, not
;;;; `c-string`, deliberately: CHICKEN's `c-string` return marshaling
;;;; copies a fresh Scheme string by scanning for a NUL terminator, which
;;;; would either read past the intended span or (for an already-owned
;;;; pointer we still need to pass to `c-free` afterward) silently drop
;;;; the only handle we have to free it. Decoding the pointer + explicit
;;;; length into a Scheme string, and freeing where this module's own
;;;; header comment says libfyaml hands over ownership, is (slibfyaml
;;;; nodes)/(slibfyaml documents)'s job, not this module's -- see the
;;;; existing `yaml` egg's own `scalar-value` (move-memory! from a
;;;; c-pointer + explicit length) for the same idiom already proven
;;;; against real libyaml event data.
;;;;
;;;; Likewise, every `size_t *`/`void **` out/iterator parameter (the
;;;; `lenp` of fy_node_get_scalar/fy_node_get_tag, the `prevp` iteration
;;;; cookie of fy_node_sequence_iterate/fy_node_mapping_iterate/
;;;; fy_diag_errors_iterate) is typed as a bare `c-pointer` here -- this
;;;; module declares the C signature faithfully and interprets nothing.

(module (slibfyaml thin)
  (
   ;; opaque handle constructors are none -- these are just tagged
   ;; c-pointer types, exported for (slibfyaml nodes)/(slibfyaml
   ;; documents) to use in their own foreign-lambda declarations and
   ;; record fields.

   ;; document lifecycle
   fy_document_build_from_string
   fy_document_build_from_file
   fy_document_destroy
   fy_document_root
   fy_document_set_root
   fy_document_insert_at
   fy_document_get_diag
   fy_document_resolve

   ;; streaming parser
   fy_parser_create
   fy_parser_destroy
   fy_parser_set_string
   fy_parser_set_input_file
   fy_parse_load_document
   fy_parser_set_diag

   ;; node predicates/type
   fy_node_get_type
   fy_node_is_null
   fy_node_get_style
   fy_node_get_tag

   ;; location
   fy_node_get_scalar_token
   fy_token_start_mark

   ;; scalar access/build
   fy_node_get_scalar
   fy_node_create_scalar_copy
   fy_node_create_sequence
   fy_node_create_mapping

   ;; sequence access
   fy_node_sequence_item_count
   fy_node_sequence_get_by_index
   fy_node_sequence_append
   fy_node_sequence_iterate

   ;; mapping access
   fy_node_mapping_item_count
   fy_node_mapping_lookup_value_by_string
   fy_node_mapping_append
   fy_node_mapping_iterate
   fy_node_pair_key
   fy_node_pair_value

   ;; path
   fy_node_by_path
   fy_node_get_path

   ;; emit
   fy_emit_document_to_string
   fy_emit_document_to_file

   ;; diagnostics
   fy_diag_create
   fy_diag_destroy
   fy_diag_set_collect_errors
   fy_diag_got_error
   fy_diag_errors_iterate

   ;; libc helper (ownership) -- named c-free, not free, so it never
   ;; shadows or is confused with anything else named `free`; same
   ;; reason alibfyaml's Libfyaml.Thin names its own binding `C_Free`
   ;; rather than `Free`.
   c-free
   )

(import scheme)
(import (chicken foreign))

(foreign-declare "#include <libfyaml.h>")

;;;; Opaque handle types -- tagged c-pointers, one per distinct libfyaml
;;;; struct, matching alibfyaml's distinct Fy_Document/Fy_Node/... types.
;;;; CHICKEN doesn't enforce this the way Ada's static typing does, but a
;;;; tagged c-pointer still generates a correctly C-typed local variable in
;;;; the generated code, so passing e.g. a fy_node where a fy_document is
;;;; expected is still a real C compiler diagnostic, not silently accepted.

(define-foreign-type fy_document (c-pointer "struct fy_document"))
(define-foreign-type fy_node (c-pointer "struct fy_node"))
(define-foreign-type fy_node_pair (c-pointer "struct fy_node_pair"))
(define-foreign-type fy_diag (c-pointer "struct fy_diag"))
(define-foreign-type fy_parser (c-pointer "struct fy_parser"))
(define-foreign-type fy_parse_cfg (c-pointer "struct fy_parse_cfg"))
(define-foreign-type fy_diag_cfg (c-pointer "struct fy_diag_cfg"))

;;;; Document lifecycle

(define fy_document_build_from_string
  (foreign-lambda fy_document "fy_document_build_from_string"
                  fy_parse_cfg c-pointer size_t))

(define fy_document_build_from_file
  (foreign-lambda fy_document "fy_document_build_from_file"
                  fy_parse_cfg c-string))

(define fy_document_destroy
  (foreign-lambda void "fy_document_destroy" fy_document))

(define fy_document_root
  (foreign-lambda fy_node "fy_document_root" fy_document))

(define fy_document_set_root
  (foreign-lambda int "fy_document_set_root" fy_document fy_node))

(define fy_document_insert_at
  (foreign-lambda int "fy_document_insert_at"
                  fy_document c-string size_t fy_node))

(define fy_document_get_diag
  (foreign-lambda fy_diag "fy_document_get_diag" fy_document))

(define fy_document_resolve
  (foreign-lambda int "fy_document_resolve" fy_document))

;;;; Streaming parser: multiple documents from one input
;;;; ((slibfyaml documents streams)'s document-stream). Distinct from
;;;; fy_document_build_from_string/_file above, which build exactly one
;;;; document.

(define fy_parser_create
  (foreign-lambda fy_parser "fy_parser_create" fy_parse_cfg))

(define fy_parser_destroy
  (foreign-lambda void "fy_parser_destroy" fy_parser))

(define fy_parser_set_string
  (foreign-lambda int "fy_parser_set_string" fy_parser c-pointer size_t))

(define fy_parser_set_input_file
  (foreign-lambda int "fy_parser_set_input_file" fy_parser c-string))

(define fy_parse_load_document
  (foreign-lambda fy_document "fy_parse_load_document" fy_parser))

(define fy_parser_set_diag
  (foreign-lambda int "fy_parser_set_diag" fy_parser fy_diag))

;;;; Node predicates/type

(define fy_node_get_type
  (foreign-lambda int "fy_node_get_type" fy_node))

(define fy_node_is_null
  (foreign-lambda bool "fy_node_is_null" fy_node))

(define fy_node_get_style
  (foreign-lambda int "fy_node_get_style" fy_node))

(define fy_node_get_tag
  (foreign-lambda c-pointer "fy_node_get_tag" fy_node c-pointer))

;;;; Source location (struct fy_mark / token marks)

(define fy_node_get_scalar_token
  (foreign-lambda c-pointer "fy_node_get_scalar_token" fy_node))
;; NULL if fyn is not a scalar node (aliases count as scalars here, per
;; libfyaml's own header). Untyped c-pointer, not a dedicated fy_token
;; foreign type: nothing in this module reads a Fy_Token's fields --
;; (slibfyaml nodes) does, via its own foreign-lambda*  accessors, once
;; it actually needs Location.

(define fy_token_start_mark
  (foreign-lambda c-pointer "fy_token_start_mark" c-pointer))
;; NULL is documented as possible ("permissable for some token types to
;; have no start marker") -- (slibfyaml nodes)'s Has_Location-equivalent
;; checks for it rather than assuming, same as alibfyaml.

;;;; Scalar node access/build

(define fy_node_get_scalar
  (foreign-lambda c-pointer "fy_node_get_scalar" fy_node c-pointer))

(define fy_node_create_scalar_copy
  (foreign-lambda fy_node "fy_node_create_scalar_copy"
                  fy_document c-pointer size_t))

(define fy_node_create_sequence
  (foreign-lambda fy_node "fy_node_create_sequence" fy_document))

(define fy_node_create_mapping
  (foreign-lambda fy_node "fy_node_create_mapping" fy_document))

;;;; Sequence node access

(define fy_node_sequence_item_count
  (foreign-lambda int "fy_node_sequence_item_count" fy_node))

(define fy_node_sequence_get_by_index
  (foreign-lambda fy_node "fy_node_sequence_get_by_index" fy_node int))

(define fy_node_sequence_append
  (foreign-lambda int "fy_node_sequence_append" fy_node fy_node))

(define fy_node_sequence_iterate
  (foreign-lambda fy_node "fy_node_sequence_iterate" fy_node c-pointer))

;;;; Mapping node access

(define fy_node_mapping_item_count
  (foreign-lambda int "fy_node_mapping_item_count" fy_node))

(define fy_node_mapping_lookup_value_by_string
  (foreign-lambda fy_node "fy_node_mapping_lookup_value_by_string"
                  fy_node c-string size_t))

(define fy_node_mapping_append
  (foreign-lambda int "fy_node_mapping_append" fy_node fy_node fy_node))

(define fy_node_mapping_iterate
  (foreign-lambda fy_node_pair "fy_node_mapping_iterate" fy_node c-pointer))

(define fy_node_pair_key
  (foreign-lambda fy_node "fy_node_pair_key" fy_node_pair))

(define fy_node_pair_value
  (foreign-lambda fy_node "fy_node_pair_value" fy_node_pair))

;;;; Path access

(define fy_node_by_path
  (foreign-lambda fy_node "fy_node_by_path"
                  fy_node c-string size_t unsigned-int))

(define fy_node_get_path
  (foreign-lambda c-pointer "fy_node_get_path" fy_node))
;; Dynamically allocated by libfyaml (caller must c-free it -- same
;; convention as fy_emit_document_to_string below).

;;;; Emit

(define fy_emit_document_to_string
  (foreign-lambda c-pointer "fy_emit_document_to_string"
                  fy_document unsigned-int))
;; Dynamically allocated by libfyaml; caller must c-free it.

(define fy_emit_document_to_file
  (foreign-lambda int "fy_emit_document_to_file"
                  fy_document unsigned-int c-string))

;;;; Diagnostics

(define fy_diag_create
  (foreign-lambda fy_diag "fy_diag_create" fy_diag_cfg))

(define fy_diag_destroy
  (foreign-lambda void "fy_diag_destroy" fy_diag))

(define fy_diag_set_collect_errors
  (foreign-lambda void "fy_diag_set_collect_errors" fy_diag bool))

(define fy_diag_got_error
  (foreign-lambda bool "fy_diag_got_error" fy_diag))

(define fy_diag_errors_iterate
  (foreign-lambda c-pointer "fy_diag_errors_iterate" fy_diag c-pointer))
;; struct fy_diag_error * really, but left untyped: nothing in this
;; module reads its fields -- (slibfyaml documents) does, via its own
;; foreign-lambda* accessors (msg/file/line/column), once it actually
;; needs Parse_Error's collected diagnostics. See PLAN.md's "Struct
;; field access" section for why those are small C snippets rather
;; than a hand-mirrored struct here.

;;;; libc helper (ownership)

(define c-free
  (foreign-lambda void "free" c-pointer))

) ;; module
