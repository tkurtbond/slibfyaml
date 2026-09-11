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
   document-parse-port
   document-root
   document-resolve!
   document-set-root!
   document-insert-at!
   document-create-scalar
   document-create-sequence
   document-create-mapping
   document->yaml-string
   document-write-to-file!
   document-write-to-port!
   emit-default emit-sort-keys
   emit-mode-block emit-mode-flow emit-mode-flow-oneline emit-mode-json
   document-destroy!
   with-document

   ;; Binding-internal: for (slibfyaml documents streams) to share this
   ;; module's Diag-collection/Parse_Cfg-building logic, its refcounted
   ;; buffer-sharing machinery, and to build documents the same way
   ;; document-parse-string/-file do. Not needed by ordinary callers of
   ;; this module.
   document-liveness-box
   document-wrap
   make-parse-cfg
   collected-errors
   buffer-ref? make-buffer-ref buffer-ref-retain! buffer-ref-release!
   )

(import scheme)
(import (chicken base))
(import (chicken foreign))
(import (chicken memory))
(import (chicken gc))
(import (chicken condition))
(import (chicken io))
(import (slibfyaml thin))
(import (slibfyaml nodes))
(import (slibfyaml))

(foreign-declare "#include <libfyaml.h>")

;;;; Refcounted buffer sharing
;;;;
;;;; A malloc'd C buffer that can be shared by more than one owner --
;;;; today, a document-stream and every document drawn from it via
;;;; document-stream-next! (see slibfyaml-documents-streams.scm's own
;;;; header comment for why: fy_parser_set_string doesn't copy its
;;;; input, so the buffer backs every document's scalars, not just the
;;;; stream's own parsing). Ported from alibfyaml's Buffer_Ref, whose
;;;; Adjust/Finalize do this refcounting automatically on assignment
;;;; and scope exit -- CHICKEN has neither, so buffer-ref-retain!/
;;;; -release! are explicit calls instead: retain! once per new holder,
;;;; release! once per holder that's done, freed only when the count
;;;; reaches zero regardless of which holder releases last.
;;;;
;;;; Every document's own owned-buffer field is uniformly either #f (no
;;;; buffer -- document-parse-file's case, and document-stream-next!'s
;;;; own Open_File-drawn case) or a buffer-ref, even document-parse-
;;;; string's -- never a bare pointer -- matching alibfyaml's own
;;;; Document.Owned_Buffer, which is unconditionally a Buffer_Ref for
;;;; the same reason: one release-on-destroy code path regardless of
;;;; whether this particular buffer ever ends up shared.

(define-record-type buffer-ref
  (make-buffer-ref-record count-box ptr)
  buffer-ref?
  (count-box buffer-ref-count-box)
  (ptr buffer-ref-ptr))

(define (make-buffer-ref ptr) (make-buffer-ref-record (vector 1) ptr))

(define (buffer-ref-retain! ref)
  (vector-set! (buffer-ref-count-box ref) 0
               (+ 1 (vector-ref (buffer-ref-count-box ref) 0)))
  ref)
;; Returns ref itself, count bumped -- CHICKEN records aren't copied
;; implicitly the way Ada's controlled Adjust fires on assignment, so
;; "sharing a copy" here just means handing the very same buffer-ref
;; object to a new holder, with its count bumped once for them.

(define (buffer-ref-release! ref)
  (when ref
    (let ((n (- (vector-ref (buffer-ref-count-box ref) 0) 1)))
      (vector-set! (buffer-ref-count-box ref) 0 n)
      (when (<= n 0) (c-free (buffer-ref-ptr ref))))))
;; A no-op on #f, so every caller can call this unconditionally on
;; whatever its own owned-buffer field holds rather than checking
;; first.

;;;; The document handle itself

(define-record-type document
  (make-document-record handle owned-buffer liveness-box)
  document?
  (handle document-handle)
  (owned-buffer document-owned-buffer)
  (liveness-box document-liveness-box))

(define (document-wrap handle owned-buffer)
  (let ((doc (make-document-record handle owned-buffer (vector #t))))
    (set-finalizer! doc document-destroy!)
    doc))
;; Shared by document-parse-string/-file below and by
;; slibfyaml-documents-streams.scm's document-stream-next! -- builds a
;; document with a fresh liveness box and the GC-finalizer backstop
;; every document needs, so neither caller has to repeat that
;; boilerplate or risk the two drifting apart.

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

(define (parse-string/labeled text file-label resolve-anchors?)
  (let* ((len (string-length text))
         (buf (c-malloc len)))
    (move-memory! text buf len)
    (handle-exceptions exn
      (begin (c-free buf) (abort exn))
      (let ((handle (parse-common
                     (lambda (cfg) (fy_document_build_from_string cfg buf len))
                     file-label resolve-anchors?)))
        (document-wrap handle (make-buffer-ref buf))))))
;; Shared by document-parse-string/document-parse-port below -- both
;; ultimately hand libfyaml a copied, malloc'd buffer via
;; fy_document_build_from_string, differing only in file-label (each
;; call site's own fixed string, matching alibfyaml's own
;; Collected_Errors reasoning: neither a Scheme string nor a CHICKEN
;; port has a real filename libfyaml could otherwise fall back to, so
;; each source kind gets an honest label of its own rather than either
;; borrowing the other's or falling back to libfyaml's synthetic,
;; run-varying "<memory-@ADDR-ADDR>").
;;
;; buf is copied from text (never a pointer into text itself, per the
;; buffer-lifetime design above) and kept alive, wrapped in a fresh
;; buffer-ref (count 1, released -- and, since nothing else ever
;; retains this particular one, thereby freed -- in document-destroy!)
;; for exactly as long as doc is. On a parse failure, buf would
;; otherwise leak (nothing would ever own or free it, since no document
;; gets built) -- freed explicitly on that path before re-raising, the
;; same double-free-vs-leak class of mistake alibfyaml's own
;; Parse_Common bug was, guarded against here from the start rather
;; than found later.

(define (document-parse-string text #!optional (resolve-anchors? #t))
  (parse-string/labeled text "(string-in-memory)" resolve-anchors?))

(define (document-parse-port port #!optional (resolve-anchors? #t))
  (parse-string/labeled (read-string #f port) "(port)" resolve-anchors?))
;; Reads port to its own end-of-file via (chicken io)'s read-string,
;; then parses exactly as document-parse-string would -- no new FFI
;; surface (see PLAN.md's Phase 10 writeup for why: no portable way to
;; obtain a real C FILE* from an arbitrary CHICKEN port to bind
;; libfyaml's own fy_document_build_from_fp against, and that call
;; isn't genuine streaming even in Ada/GNAT's own C_Streams escape
;; hatch -- a single call there typically reads the entire remaining
;; file in one internal fread() regardless of document count, so
;; reading the port fully upfront loses nothing in practice). Only the
;; first document of a multi-document port's content is parsed, same
;; "first document only" semantics as document-parse-string/-file --
;; use (slibfyaml documents streams) for a real multi-document stream
;; instead. file-label is the fixed "(port)", distinct from
;; document-parse-string's own "(string-in-memory)", so a parse
;; failure's reported file doesn't misleadingly suggest the caller
;; passed a literal string constant.

(define (document-parse-file path #!optional (resolve-anchors? #t))
  (let ((handle (parse-common
                 (lambda (cfg) (fy_document_build_from_file cfg path))
                 #f resolve-anchors?)))
    (document-wrap handle #f)))
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

(define (document-write-to-port! doc port #!optional (flags emit-default))
  (write-string (document->yaml-string doc flags) #f port))
;; Emit doc to an already-open CHICKEN output port -- no alibfyaml
;; equivalent exists to port from (Ada's own Text_IO-based I/O has the same
;; GNAT-specific-extension problem on the write side libfyaml's own
;; fy_emit_document_to_fp would have here: no portable FILE* out of a
;; CHICKEN port to bind it against -- see PLAN.md's Phase 10 writeup).
;; Composes document->yaml-string (which already does its own
;; check-document-live! and raise-emit-error) with (chicken io)'s own
;; write-string rather than adding new FFI surface -- symmetric with
;; document-parse-port's own composition on the read side.

;;;; Destruction

(define (document-destroy! doc)
  (when (document-live? doc)
    (fy_document_destroy (document-handle doc))
    (buffer-ref-release! (document-owned-buffer doc))
    (vector-set! (document-liveness-box doc) 0 #f)))
;; buffer-ref-release! only frees the underlying buffer once every
;; holder (this document, and -- for one drawn from a string-backed
;; document-stream -- that stream itself, and every other document
;; drawn from it -- see slibfyaml-documents-streams.scm) has released
;; its own share; a no-op if this document's owned-buffer is #f, so no
;; guard is needed here for that case.
;;
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
