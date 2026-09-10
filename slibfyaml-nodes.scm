;;;; slibfyaml-nodes.scm
;;;;
;;;; (slibfyaml nodes), ported from alibfyaml's Libfyaml.Nodes: `node` is
;;;; a cheap, non-owning handle onto a node in a parsed or
;;;; in-progress-of-being-built YAML document tree. Node values stay
;;;; valid for as long as the owning document is alive -- see the
;;;; "Node validity after its document is gone" enforcement below, which
;;;; is where this module goes further than alibfyaml's Ada (whose
;;;; equivalent contract is documentation-only; see PLAN.md's Memory
;;;; model section and the note added to alibfyaml's own
;;;; libfyaml-nodes.ads).
;;;;
;;;; This module does NOT import (slibfyaml documents), deliberately:
;;;; the owner-liveness check below needs to know only whether a node's
;;;; owning document is still alive, not anything else about documents,
;;;; so the two modules share a liveness *box* (a one-element mutable
;;;; vector: #t while the document is alive, #f once destroyed) rather
;;;; than this module holding a reference to the actual `document`
;;;; record type (which lives in (slibfyaml documents), and which
;;;; itself needs to build `node` values via node-wrap -- an import in
;;;; both directions isn't something CHICKEN's module system supports
;;;; for two separately-compiled units). (slibfyaml documents) creates
;;;; one liveness box per document, hands it to every node-wrap call
;;;; for nodes drawn from that document, and flips it to #f in
;;;; document-destroy! -- a single flip invalidates every node drawn
;;;; from that document at once, without either module needing to know
;;;; the other's record layout.

(module (slibfyaml nodes)
  (
   node? node-valid? null-node
   node-kind
   node-scalar? node-sequence? node-mapping?
   node-scalar-value
   node-length node-item
   node-value node-has-key?
   node-iterate-items node-iterate-pairs
   node-by-path node-path

   ;; Binding-internal: bridges to/from the raw Thin handle and the
   ;; shared liveness box. Used by (slibfyaml documents) and (later)
   ;; (slibfyaml documents streams); not needed by ordinary callers of
   ;; this module.
   node-wrap
   node-raw
   node-owner-box
   )

(import scheme)
(import (chicken base))
(import (chicken foreign))
(import (slibfyaml thin))
(import (slibfyaml))

(foreign-declare "#include <libfyaml.h>")
;; Needed again here (not just in slibfyaml-thin.scm) because
;; foreign-declare's #include is per compilation unit, not shared
;; across separately-compiled modules -- this module's own
;; foreign-value lookups (FYNT_*, FYNWF_PTR_YAML below) need the enum
;; declarations visible to the C compiler when *this* file is compiled.

;;;; The node handle itself

(define-record-type node
  (make-node handle owner-box)
  node?
  (handle node-raw)
  (owner-box node-owner-box))

(define null-node (make-node #f #f))
;; The "no node" handle: returned by lookups that find nothing. Has no
;; owner box -- it isn't tied to any particular document's lifetime,
;; and never needs a liveness check (see check-node-live! below).

(define (node-wrap handle owner-box)
  (if handle (make-node handle owner-box) null-node))
;; libfyaml's own out-of-range/not-found convention for the raw
;; functions this wraps is to return NULL, which CHICKEN's foreign-
;; lambda marshaling surfaces as #f -- node-wrap turns that uniformly
;; into null-node rather than a node wrapping a null handle, so every
;; caller has exactly one "not found" value to check against
;; (node-valid?), matching alibfyaml's own Wrap.

(define (node-valid? n) (and (node-raw n) #t))
;; True unless N is null-node. Independent of, and checked separately
;; from, owner-liveness below -- a null-handle check and an "is my
;; owner still alive" check are different failure modes (see
;; PLAN.md's Error handling section on why missing-key/data get a
;; distinct 'consumed condition kind from 'use-after-free, the same
;; reasoning applies to this null-check/liveness-check split).

(define (check-node-live! n)
  (let ((box (node-owner-box n)))
    (when (and box (not (vector-ref box 0)))
      (raise-use-after-free
       "node used after its owning document was destroyed"))))
;; null-node and any node with no owner (none exist yet as of this
;; module -- (slibfyaml documents)'s freshly-built-but-not-yet-attached
;; nodes will, once Create_Scalar/_Sequence/_Mapping exist) skip this
;; check and fall through to node-valid?'s null-handle check instead,
;; per PLAN.md's design: the two checks are independent, not layered.

;;;; Node kind

(define FYNT_SCALAR   (foreign-value "FYNT_SCALAR" int))
(define FYNT_SEQUENCE (foreign-value "FYNT_SEQUENCE" int))
(define FYNT_MAPPING  (foreign-value "FYNT_MAPPING" int))

(define (node-kind n)
  (check-node-live! n)
  (let ((raw-kind (fy_node_get_type (node-raw n))))
    (cond ((= raw-kind FYNT_SCALAR) 'scalar)
          ((= raw-kind FYNT_SEQUENCE) 'sequence)
          ((= raw-kind FYNT_MAPPING) 'mapping)
          (else (error "slibfyaml: fy_node_get_type returned an unknown value"
                       raw-kind)))))

(define (node-scalar? n) (eq? 'scalar (node-kind n)))
(define (node-sequence? n) (eq? 'sequence (node-kind n)))
(define (node-mapping? n) (eq? 'mapping (node-kind n)))

;;;; Scalar node access

(define (node-scalar-value n)
  (check-node-live! n)
  (assert (node-scalar? n) "node-scalar-value: not a scalar node" n)
  (let* ((lenp (c-malloc (foreign-type-size "size_t")))
         (ptr (fy_node_get_scalar (node-raw n) lenp))
         (len (size_t-ref lenp)))
    (c-free lenp)
    (decode-c-string ptr len)))

;;;; Sequence node access

(define (node-length n)
  (check-node-live! n)
  (case (node-kind n)
    ((sequence) (fy_node_sequence_item_count (node-raw n)))
    ((mapping) (fy_node_mapping_item_count (node-raw n)))
    (else (error "slibfyaml: node-length: not a sequence or mapping" n))))
;; Item count of a sequence, or pair count of a mapping -- same dual
;; purpose as alibfyaml's Length.

(define (node-item n index)
  (check-node-live! n)
  (assert (node-sequence? n) "node-item: not a sequence node" n)
  (node-wrap (fy_node_sequence_get_by_index (node-raw n) (- index 1))
             (node-owner-box n)))
;; 1-based, matching alibfyaml's Item -- libfyaml's own
;; fy_node_sequence_get_by_index is 0-based, hence the offset. Out of
;; range returns null-node (via node-wrap's #f-handle case) rather
;; than raising, passing through libfyaml's own out-of-range behavior
;; for this lookup, same as alibfyaml.

(define (node-iterate-items seq visit)
  (check-node-live! seq)
  (assert (node-sequence? seq) "node-iterate-items: not a sequence node" seq)
  (let ((cookie (make-pointer-cell))
        (owner (node-owner-box seq)))
    (let loop ()
      (let ((item (fy_node_sequence_iterate (node-raw seq) cookie)))
        (when item
          (visit (node-wrap item owner))
          (loop))))
    (c-free cookie)))
;; visit is called as (visit element) -- one argument, matching a
;; sequence's natural shape. See PLAN.md's Error handling / API
;; surface sketch sections for why this is a separate name from
;; node-iterate-pairs rather than one name dispatching on node-kind:
;; the two kinds' visitor shapes genuinely differ (one argument here,
;; two below), and forcing both through a single uniform shape would
;; distort whichever kind isn't the caller's.

(define (node-iterate-pairs map visit)
  (check-node-live! map)
  (assert (node-mapping? map) "node-iterate-pairs: not a mapping node" map)
  (let ((cookie (make-pointer-cell))
        (owner (node-owner-box map)))
    (let loop ()
      (let ((pair (fy_node_mapping_iterate (node-raw map) cookie)))
        (when pair
          (visit (node-wrap (fy_node_pair_key pair) owner)
                 (node-wrap (fy_node_pair_value pair) owner))
          (loop))))
    (c-free cookie)))
;; visit is called as (visit key value) -- two arguments, matching a
;; mapping's natural shape.

;;;; Mapping node access

(define (node-value map key)
  (check-node-live! map)
  (assert (node-mapping? map) "node-value: not a mapping node" map)
  (node-wrap (fy_node_mapping_lookup_value_by_string
              (node-raw map) key (string-length key))
             (node-owner-box map)))
;; The value associated with the string-scalar key Key, or null-node
;; if the mapping has no such key -- same as alibfyaml's Value.

(define (node-has-key? map key) (node-valid? (node-value map key)))

;;;; Path access

(define FYNWF_PTR_YAML (foreign-value "FYNWF_PTR_YAML" unsigned-int))

(define (node-by-path n path)
  (check-node-live! n)
  (node-wrap (fy_node_by_path (node-raw n) path (string-length path)
                               FYNWF_PTR_YAML)
             (node-owner-box n)))
;; Look up a descendant node by libfyaml's native path syntax, e.g.
;; "/server/port". Returns null-node if the path cannot be resolved --
;; same as alibfyaml's By_Path.

(define (node-path n)
  (check-node-live! n)
  (let ((ptr (fy_node_get_path (node-raw n))))
    (if ptr
        (let ((s (nul-terminated-c-string-at ptr)))
          (c-free ptr)
          s)
        "")))
;; N's own path address relative to the document root, in the same
;; syntax node-by-path accepts -- the inverse of node-by-path. Works
;; on a node of any kind, mapping/sequence included, not just scalars
;; (unlike a future node-location, which will be scalar-only -- see
;; PLAN.md's "Location and Path" section for why both exist). The
;; document root's own path is "/" -- alibfyaml confirmed this live
;; against libfyaml despite the C header's own claim that this
;; returns NULL for the root; the "" fallback above is purely
;; defensive for whatever the *documented* NULL case might be, should
;; it ever actually occur, not for the root specifically.

) ;; module
