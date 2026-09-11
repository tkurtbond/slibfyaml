;;;; slibfyaml-scheme.scm
;;;;
;;;; (slibfyaml scheme): the value-materializing convenience API --
;;;; node->scheme, load-string, load-file. Unlike every other module in
;;;; this binding, this one has no alibfyaml source to port: Ada is
;;;; statically typed and has no equivalent "decode to one generic
;;;; native value" operation, so this design is specific to slibfyaml,
;;;; motivated instead by parity with the existing `yaml`/`libyaml`
;;;; Chicken eggs -- see PLAN.md's "Value-materializing convenience
;;;; API" section for the full rationale (fixing `yaml` egg's actual
;;;; multi-document limitation without inheriting `libyaml` egg's
;;;; awkward callable-with-an-index fix for the same gap).
;;;;
;;;; A pure consumer of the handle-based core: no new C calls, no new
;;;; condition kinds, nothing beyond what (slibfyaml nodes)/
;;;; (slibfyaml documents)/(slibfyaml documents streams) already
;;;; provide -- this is exactly why the roadmap put the handle-based
;;;; core, typed scalars, and streaming (phases 2/3/6) before this one.

(module (slibfyaml scheme)
  (
   node->scheme
   load-string
   load-file
   )

(import scheme)
(import (chicken base))
(import (slibfyaml nodes))
(import (slibfyaml documents))
(import (slibfyaml documents streams))

(define (node->scheme n)
  (case (node-kind n)
    ((mapping) (mapping->alist n))
    ((sequence) (sequence->list n))
    ((scalar) (scalar->scheme n))))
;; Recursively decodes any node (not just a document root -- a genuine
;; advantage of building this on the handle-based core, since neither
;; existing egg's decoder can be pointed at a sub-tree) into plain
;; Scheme data. Anchors/aliases need no special handling here at all:
;; by the time node->scheme sees a node, resolution (default #t on
;; parse, or via document-resolve!) has already replaced every alias
;; with its resolved content -- unlike `yaml` egg, which has to
;; hand-roll an anchor hash-table during event parsing to get the same
;; result. Because the shape is always known from node-kind while
;; decoding, this direction has none of `yaml` egg's mapping/sequence
;; ambiguity either -- that ambiguity only bites an *emitter*, which
;; has to guess a Scheme value's intended YAML shape from its structure
;; alone; a pure decoder never has to guess.

(define (mapping->alist n)
  (let ((pairs '()))
    (node-iterate-pairs n (lambda (key value)
                            (set! pairs (cons (cons (node->scheme key) (node->scheme value))
                                               pairs))))
    (reverse pairs)))
;; Keys are decoded via node->scheme too, same as values -- a plain
;; string key is the overwhelmingly common case, but nothing here
;; assumes it; a key that happens to parse as e.g. an integer or
;; boolean scalar decodes the same way any other scalar would.

(define (sequence->list n)
  (let ((items '()))
    (node-iterate-items n (lambda (item) (set! items (cons (node->scheme item) items))))
    (reverse items)))

(define (scalar->scheme n)
  (cond ((node-null-value? n) '())
        ((node-boolean? n) (node-boolean-value n))
        ((node-integer? n) (node-integer-value n))
        ((node-float? n) (node-float-value n))
        (else (node-scalar-value n))))
;; Integer is checked before float deliberately, not just following the
;; PLAN.md sketch's own listed order: any valid integer text is also
;; valid float grammar (confirmed back in Phase 3's own test-scalars.scm
;; -- e.g. "42" is both node-integer? and node-float?), so checking
;; float first would silently widen every plain integer into a flonum.
;; Boolean/null never overlap with int/float/each other's grammar, so
;; their relative order doesn't affect correctness -- checked first
;; here purely because they're the cheapest, most specific shapes to
;; rule out. node-scalar-value as the fallback never rejects any text,
;; same as the typed core's own node-string-value.

;;;; Multi-document entry points

(define (load-via-stream stream resolve-anchors?)
  (let ((results '()))
    (dynamic-wind
     (lambda () #f)
     (lambda ()
       (let loop ()
         (when (document-stream-has-next? stream)
           (with-document (doc (document-stream-next! stream))
             (when resolve-anchors? (document-resolve! doc))
             (set! results (cons (node->scheme (document-root doc)) results)))
           (loop))))
     (lambda () (document-stream-destroy! stream)))
    (reverse results)))
;; Shared by load-string/load-file below. document-stream-open-string/
;; -open-file have no resolve-anchors? parameter of their own (matching
;; alibfyaml's Open_String/Open_File exactly -- see Phase 6), so
;; resolve-anchors? here is honored by an explicit document-resolve!
;; call per document instead, rather than at stream-open time. Each
;; document is destroyed (via with-document) immediately after
;; decoding, before the next is even fetched -- nothing from the tree
;; needs to survive past node->scheme, the whole point of this API
;; being that the caller never touches a document/node at all. The
;; stream itself is destroyed via dynamic-wind regardless of how the
;; loop above exits (including a parse error partway through, which
;; propagates as (exn slibfyaml parse) same as document-stream-next!
;; itself raises it).

(define (load-string text #!optional (resolve-anchors? #t))
  (load-via-stream (document-stream-open-string text) resolve-anchors?))

(define (load-file path #!optional (resolve-anchors? #t))
  (load-via-stream (document-stream-open-file path) resolve-anchors?))
;; Always return a list of decoded documents, even for single-document
;; input (a length-1 list) -- no thunk, no index argument, no -1
;; sentinel, fixing `yaml` egg's actual limitation (yaml-load collapses
;; its parse seed to (car seed) on document-end, so it can only ever
;; return the first document) without inheriting `libyaml` egg's
;; awkward fix for the same problem (its yaml->ss returns a callable
;; you invoke with a document index). (car (load-string ...)) is
;; exactly as short as libyaml egg's own ((yaml->ss ...)) for the
;; single-document case anyway -- no load-string-first/load-file-first
;; convenience wrapper planned, per PLAN.md's own note, until a real
;; call site shows one is actually wanted.

) ;; module
