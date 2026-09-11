;;;; slibfyaml-documents.scm
;;;;
;;;; (slibfyaml documents), ported from alibfyaml's Libfyaml.Documents:
;;;; `document` owns a tree of (slibfyaml nodes)'s node handles. Unlike
;;;; Ada's RAII (Ada.Finalization.Limited_Controlled, deterministic
;;;; Finalize on scope exit), CHICKEN has no deterministic destructors --
;;;; see PLAN.md's "Document ownership: no RAII, so what replaces it?"
;;;; for the two mechanisms used together here: explicit,
;;;; idempotent `document-destroy!`, backed by a GC finalizer that is a
;;;; backstop, not a substitute (it runs at an unpredictable point, not
;;;; immediately).
;;;;
;;;; The buffer-lifetime handling here (document-parse-string always
;;;; copying its input into a document-owned malloc'd buffer, never
;;;; handing libfyaml a pointer into CHICKEN-managed string storage) is
;;;; the load-bearing design decision from PLAN.md's "buffer-lifetime
;;;; problem" section -- worse in CHICKEN than in Ada, because CHICKEN's
;;;; c-string marshaling is transient (valid only for the call) and its
;;;; heap is copying/moving (a raw pointer into a live Scheme string's
;;;; bytes can be invalidated by a later GC even while the string is
;;;; still reachable). Never pass a bare Scheme string where libfyaml
;;;; will retain a pointer past the call.

(module (slibfyaml documents)
  (
   document?
   document-parse-string
   document-parse-file
   document-root
   document-resolve!
   document-set-root!
   document-insert-at!
   document-create-scalar
   document-create-sequence
   document-create-mapping
   document->yaml-string
   document-write-to-file!
   emit-default emit-sort-keys
   emit-mode-block emit-mode-flow emit-mode-flow-oneline emit-mode-json
   document-destroy!
   with-document

   ;; Binding-internal: for (slibfyaml documents streams), once it
   ;; exists, to share this module's Diag-collection/Parse_Cfg-building
   ;; logic and to attach documents it produces to the same kind of
   ;; liveness box. Not needed by ordinary callers of this module.
   document-liveness-box
   )

(import scheme)
(import (chicken base))
(import (chicken foreign))
(import (chicken memory))
(import (chicken gc))
(import (chicken condition))
(import (slibfyaml thin))
(import (slibfyaml nodes))
(import (slibfyaml))

(foreign-declare "#include <libfyaml.h>")

;;;; The document handle itself

(define-record-type document
  (make-document-record handle owned-buffer liveness-box)
  document?
  (handle document-handle)
  (owned-buffer document-owned-buffer set-document-owned-buffer!)
  (liveness-box document-liveness-box))

(define (document-live? doc) (vector-ref (document-liveness-box doc) 0))

(define (check-document-live! doc)
  (unless (document-live? doc)
    (raise-use-after-free "document used after it was destroyed")))
;; alibfyaml's Ada Document has no equivalent check on its own
;; operations (Root, etc.) -- only Node's contract is documented as
;; tied to Document's lifetime. Checking here too is the same
;; extra-defensiveness call PLAN.md's Memory model section already
;; made for nodes, applied consistently to document-level operations.

;;;; Building an fy_parse_cfg on the C heap
;;;;
;;;; See PLAN.md's "Struct field access" section: a small foreign-
;;;; lambda* snippet that lets the C compiler compute struct fy_parse_cfg's
;;;; real layout, rather than a hand-mirrored CHICKEN record standing in
;;;; for it -- avoids the ABI-drift risk a hand-mirrored struct carries
;;;; across libfyaml versions.

(define make-parse-cfg
  (foreign-lambda* c-pointer ((unsigned-int flags) (c-pointer diag))
    "struct fy_parse_cfg *cfg = malloc(sizeof(struct fy_parse_cfg));"
    "cfg->search_path = NULL;"
    "cfg->flags = flags;"
    "cfg->userdata = NULL;"
    "cfg->diag = diag;"
    "C_return(cfg);"))

(define FYPCF_RESOLVE_DOCUMENT (foreign-value "FYPCF_RESOLVE_DOCUMENT" unsigned-int))

;;;; Diagnostics: collecting and formatting parse errors
;;;;
;;;; Same small-C-snippet approach as above for struct fy_diag_error's
;;;; fields (type/module/fyt/msg/file/line/column, per the header) --
;;;; only the four fields actually used are read.

(define diag-error-msg
  (foreign-lambda* c-pointer ((c-pointer e))
    "C_return((char *)((struct fy_diag_error *)e)->msg);"))
(define diag-error-file
  (foreign-lambda* c-pointer ((c-pointer e))
    "C_return((char *)((struct fy_diag_error *)e)->file);"))
(define diag-error-line
  (foreign-lambda* int ((c-pointer e))
    "C_return(((struct fy_diag_error *)e)->line);"))
(define diag-error-column
  (foreign-lambda* int ((c-pointer e))
    "C_return(((struct fy_diag_error *)e)->column);"))

(define (join-with-newlines strings)
  (cond ((null? strings) "")
        ((null? (cdr strings)) (car strings))
        (else (string-append (car strings) "\n"
                              (join-with-newlines (cdr strings))))))

(define (collected-errors diag file-override)
  ;; Returns (values message first-file first-line first-column).
  ;; file-override forces every line's file field to a fixed label
  ;; (document-parse-string passes "(string-in-memory)": libfyaml has
  ;; no real filename to report for string input and would otherwise
  ;; fall back to a synthetic, run-varying "<memory-@ADDR-ADDR>" label
  ;; -- same reasoning, and same fixed label, as alibfyaml's
  ;; Collected_Errors). document-parse-file passes #f: each error's
  ;; own `file` field already correctly echoes back the real path.
  (let ((cookie (make-pointer-cell))
        (lines '())
        (first-file #f) (first-line #f) (first-column #f))
    (let loop ()
      (let ((e (fy_diag_errors_iterate diag cookie)))
        (when e
          (let* ((msg (nul-terminated-c-string-at (diag-error-msg e)))
                 (raw-file-ptr (diag-error-file e))
                 (file (or file-override
                           (and raw-file-ptr (nul-terminated-c-string-at raw-file-ptr))
                           "?"))
                 (line (diag-error-line e))
                 (column (diag-error-column e)))
            (unless first-file
              (set! first-file file)
              (set! first-line line)
              (set! first-column column))
            (set! lines (cons (string-append file ":" (number->string line) ":"
                                              (number->string column) ": error: " msg)
                               lines)))
          (loop))))
    (c-free cookie)
    (values (join-with-newlines (reverse lines)) first-file first-line first-column)))

(define (parse-common build file-override resolve-anchors?)
  ;; build : (cfg-pointer) -> raw fy_document handle (or #f on failure)
  ;; Shared by document-parse-string/document-parse-file (and, later,
  ;; (slibfyaml documents streams)'s own one-document-at-a-time calls),
  ;; matching alibfyaml's own Parse_Common. Diag is created fresh and
  ;; destroyed exactly once on every path -- success or failure --
  ;; here in one place, rather than risking the double-destroy bug
  ;; alibfyaml hit once when this logic was still duplicated per caller
  ;; (see its PLAN.md, "Parse_Common double-free on every parse
  ;; failure").
  (let ((diag (fy_diag_create #f)))
    (fy_diag_set_collect_errors diag #t)
    (let* ((flags (if resolve-anchors? FYPCF_RESOLVE_DOCUMENT 0))
           (cfg (make-parse-cfg flags diag))
           (handle (build cfg)))
      (c-free cfg)
      (if handle
          (begin (fy_diag_destroy diag) handle)
          (let-values (((message file line column) (collected-errors diag file-override)))
            (fy_diag_destroy diag)
            (raise-parse-error message file line column))))))

;;;; Parse

(define (document-parse-string text #!optional (resolve-anchors? #t))
  (let* ((len (string-length text))
         (buf (c-malloc len)))
    (move-memory! text buf len)
    (handle-exceptions exn
      (begin (c-free buf) (abort exn))
      (let* ((handle (parse-common
                       (lambda (cfg) (fy_document_build_from_string cfg buf len))
                       "(string-in-memory)" resolve-anchors?))
             (doc (make-document-record handle buf (vector #t))))
        (set-finalizer! doc document-destroy!)
        doc))))
;; buf is copied from text (never a pointer into text itself, per the
;; buffer-lifetime design above) and kept alive in Owned_Buffer for
;; exactly as long as doc is, freed in document-destroy!. On a parse
;; failure, buf would otherwise leak (nothing would ever own or free
;; it, since no document gets built) -- freed explicitly on that path
;; before re-raising, the same double-free-vs-leak class of mistake
;; alibfyaml's own Parse_Common bug was, guarded against here from the
;; start rather than found later.

(define (document-parse-file path #!optional (resolve-anchors? #t))
  (let* ((handle (parse-common
                  (lambda (cfg) (fy_document_build_from_file cfg path))
                  #f resolve-anchors?))
         (doc (make-document-record handle #f (vector #t))))
    (set-finalizer! doc document-destroy!)
    doc))
;; No Owned_Buffer: libfyaml reads/mmaps the file itself, matching
;; alibfyaml's confirmed finding that file-based input has no
;; equivalent buffer-lifetime hazard.

;;;; Tree access

(define (document-root doc)
  (check-document-live! doc)
  (node-wrap (fy_document_root (document-handle doc)) (document-liveness-box doc)))
;; The document's root node, or null-node if the document has none yet
;; -- same as alibfyaml's Root.

(define (document-resolve! doc)
  (check-document-live! doc)
  (let ((status (fy_document_resolve (document-handle doc))))
    (when (not (= status 0))
      (raise-resolve-error "fy_document_resolve failed"))))
;; Resolve anchors, aliases, and merge keys in doc in place -- the same
;; resolution document-parse-string/-file perform automatically when
;; resolve-anchors? is #t, but usable on a document parsed with
;; resolve-anchors? #f (to inspect the raw, unresolved tree first via
;; node-alias?/node-tag) or, once document-create-*/document-set-root!
;; can build one, a document built programmatically. Same as
;; alibfyaml's Resolve. Raises (exn slibfyaml resolve) on failure (e.g.
;; a merge-key reference loop -- libfyaml detects this itself and
;; returns a clean failure status rather than hanging, confirmed by
;; alibfyaml against the same fixture this binding's own test-anchors
;; reuses); libfyaml's header doesn't document what state doc is left
;; in on failure (partial resolution is possible), so treat doc as
;; unreliable afterward rather than assuming either full resolution or
;; a clean rollback -- same caveat alibfyaml's own doc comment states.

;;;; Build

(define (document-set-root! doc n)
  (check-document-live! doc)
  (check-node-live! n)
  (let ((status (fy_document_set_root (document-handle doc) (node-raw n))))
    (when (not (= status 0))
      (error "slibfyaml: fy_document_set_root failed" doc n))))
;; Make n (typically freshly built via document-create-scalar/-sequence/
;; -mapping below) the document's root node -- same as alibfyaml's
;; Set_Root. Unlike document-insert-at!, n is attached outright, not
;; merged: fy_document_set_root's own header documents no unref of n
;; (only that the *previous* root, if any, is freed) -- n is NOT
;; consumed, and remains valid and usable afterward. A nonzero status
;; is a plain (error ...), not a slibfyaml condition, matching
;; alibfyaml's own choice of a generic Program_Error here rather than
;; one of its five domain exceptions -- this "shouldn't happen" given a
;; live document and a live node, the same class of internal-invariant
;; failure as node-kind's own unknown-fy_node_get_type-result error.

(define (document-insert-at! doc path n)
  (check-document-live! doc)
  (check-node-live! n)
  (let ((status (fy_document_insert_at (document-handle doc) path
                                        (string-length path) (node-raw n))))
    (set-node-raw! n #f)
    (set-node-consumed?! n #t)
    (when (not (= status 0))
      (error "slibfyaml: fy_document_insert_at failed for path" path))))
;; Insert/replace the node at path (libfyaml native path syntax, e.g.
;; "/server") with n, following libfyaml's fy_node_insert merge rules
;; (a scalar overwrites the target; a sequence/mapping n is appended
;; into an existing sequence/mapping target rather than replacing it
;; outright) -- same as alibfyaml's Insert_At.
;;
;; n is ALWAYS consumed by this call -- libfyaml's header is explicit
;; that the node is unconditionally unref'ed, on both success and
;; failure, and freed outright if that drops its reference count to
;; zero. A freshly-built n (document-create-scalar/-sequence/-mapping,
;; not yet attached anywhere else) has no other reference, so this
;; applies on success just as much as on failure -- ported directly
;; from a bug alibfyaml already hit and confirmed live with valgrind:
;; an earlier version of that binding only nulled its own N out on
;; failure, and a "successful" merge left N pointing at memory libfyaml
;; had already freed (masked without valgrind, since the freed bytes
;; happened to still look plausible). n's raw handle and consumed? flag
;; are therefore both updated here unconditionally, before even
;; checking status: any further accessor call on n raises
;; (exn slibfyaml consumed) instead of touching freed memory. If the
;; attached result is needed, re-fetch it from path via node-by-path --
;; never assume n itself still holds anything. Like document-set-root!,
;; a nonzero status is a plain (error ...), matching alibfyaml's own
;; Program_Error choice here.

(define (document-create-scalar doc value)
  (check-document-live! doc)
  (let* ((len (string-length value))
         (buf (c-malloc len)))
    (move-memory! value buf len)
    (let ((result (fy_node_create_scalar_copy (document-handle doc) buf len)))
      (c-free buf)
      (node-wrap result (document-liveness-box doc)))))
;; Build a new scalar node holding a copy of value -- same as
;; alibfyaml's Create_Scalar. buf only needs to survive this one call:
;; fy_node_create_scalar_copy's own "_copy" name (confirmed against the
;; installed header) means libfyaml copies the bytes internally, unlike
;; document-parse-string's buf, which the resulting document keeps
;; zero-copy references into for its entire lifetime -- so buf is freed
;; right after the call, not retained in the document record. The node
;; is not yet attached to the tree; attach it with document-set-root!,
;; document-insert-at!, node-append!, or node-append-pair!.

(define (document-create-sequence doc)
  (check-document-live! doc)
  (node-wrap (fy_node_create_sequence (document-handle doc)) (document-liveness-box doc)))

(define (document-create-mapping doc)
  (check-document-live! doc)
  (node-wrap (fy_node_create_mapping (document-handle doc)) (document-liveness-box doc)))

;;;; Emit

(define emit-default (foreign-value "FYECF_DEFAULT" unsigned-int))
(define emit-sort-keys (foreign-value "FYECF_SORT_KEYS" unsigned-int))
(define emit-mode-block (foreign-value "FYECF_MODE_BLOCK" unsigned-int))
(define emit-mode-flow (foreign-value "FYECF_MODE_FLOW" unsigned-int))
(define emit-mode-flow-oneline (foreign-value "FYECF_MODE_FLOW_ONELINE" unsigned-int))
(define emit-mode-json (foreign-value "FYECF_MODE_JSON" unsigned-int))
;; Same subset alibfyaml binds, out of libfyaml's much larger emitter-
;; config flag set (width/indent controls, comment/tag/label-stripping,
;; document-marker controls, etc.) -- bind exactly what's needed, same
;; discipline as the C function surface itself. Combine with CHICKEN's
;; own bitwise-ior-on-fixnums (e.g. `(chicken fixnum)`'s `fxior`), e.g.
;; (fxior emit-sort-keys emit-mode-block) -- these are plain integers,
;; not a distinct flags type, so slibfyaml doesn't need its own
;; combinator on top.

(define (document->yaml-string doc #!optional (flags emit-default))
  (check-document-live! doc)
  (let ((ptr (fy_emit_document_to_string (document-handle doc) flags)))
    (if (not ptr)
        (raise-emit-error "fy_emit_document_to_string failed")
        (let ((s (nul-terminated-c-string-at ptr)))
          (c-free ptr)
          s))))
;; Emit doc to a string -- same as alibfyaml's To_YAML. Unlike
;; node-scalar-value's zero-copy spans, fy_emit_document_to_string
;; hands back a genuinely NUL-terminated, freshly allocated buffer (per
;; its own header, caller must free it) -- nul-terminated-c-string-at
;; is the right decoder here, not decode-c-string.

(define (document-write-to-file! doc path #!optional (flags emit-default))
  (check-document-live! doc)
  (let ((status (fy_emit_document_to_file (document-handle doc) flags path)))
    (when (not (= status 0))
      (raise-emit-error
       (string-append "fy_emit_document_to_file failed for \"" path "\"")))))
;; Emit doc to the file at path -- same as alibfyaml's Write_To_File.

;;;; Destruction

(define (document-destroy! doc)
  (when (document-live? doc)
    (fy_document_destroy (document-handle doc))
    (let ((buf (document-owned-buffer doc)))
      (when buf
        (c-free buf)
        (set-document-owned-buffer! doc #f)))
    (vector-set! (document-liveness-box doc) 0 #f)))
;; Idempotent: a second call (whether explicit, or the GC finalizer
;; firing after an explicit call already ran) is a safe no-op, never a
;; second fy_document_destroy/c-free -- see PLAN.md's "Document
;; ownership" section for why this matters (the double-free class of
;; bug alibfyaml hit once in Parse_Common, here guarded against by
;; construction: document-live? is false after the first call, so
;; every subsequent call's body is skipped entirely).

(define-syntax with-document
  (syntax-rules ()
    ((_ (doc expr) body ...)
     (let ((doc expr))
       (dynamic-wind
        (lambda () #f)
        (lambda () body ...)
        (lambda () (document-destroy! doc)))))))
;; Recommended idiom for anything that isn't itself long-lived,
;; analogous to call-with-input-file -- deterministic cleanup at the
;; end of body, not left to whenever the GC finalizer happens to run.
;;
;; Example:
;;   (with-document (doc (document-parse-file "config.yaml"))
;;     (node-value (document-root doc) "server"))

) ;; module
