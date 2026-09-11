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
   node-value node-has-key? node-required
   node-iterate-items node-iterate-pairs
   node-by-path node-path

   node-null-value?
   node-integer? node-float? node-boolean?
   node-integer-value node-float-value node-boolean-value node-string-value

   node-append! node-append-pair!

   ;; Binding-internal: bridges to/from the raw Thin handle and the
   ;; shared liveness box. Used by (slibfyaml documents) and (later)
   ;; (slibfyaml documents streams); not needed by ordinary callers of
   ;; this module.
   node-wrap
   node-raw
   node-owner-box
   set-node-raw!
   set-node-consumed?!
   check-node-live!
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
  (%make-node handle owner-box consumed?)
  node?
  (handle node-raw set-node-raw!)
  (owner-box node-owner-box)
  (consumed? node-consumed? set-node-consumed?!))

(define (make-node handle owner-box) (%make-node handle owner-box #f))

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
;; True unless N is null-node -- also true, misleadingly, right after
;; document-insert-at! consumes N (see below), same as it's already
;; misleading right after N's owning document is destroyed: node-valid?
;; is deliberately a cheap null-handle check only, independent of and
;; checked separately from both owner-liveness and consumption below --
;; three different failure modes, matching PLAN.md's Error handling
;; section on why missing-key/data/use-after-free/consumed are all
;; distinct condition kinds rather than one.

(define (check-node-live! n)
  (when (node-consumed? n)
    (raise-consumed
     "node used after being consumed by document-insert-at!"))
  (let ((box (node-owner-box n)))
    (when (and box (not (vector-ref box 0)))
      (raise-use-after-free
       "node used after its owning document was destroyed"))))
;; The single guard every accessor below calls first -- checks
;; consumption before owner-liveness, since a consumed node's handle
;; has already been nulled by document-insert-at! regardless of which
;; document it came from. null-node and any node with no owner (a
;; freshly-built-but-not-yet-attached node from document-create-scalar/
;; -sequence/-mapping still has one -- see slibfyaml-documents.scm)
;; are never consumed and skip the owner-liveness check too, falling
;; through to node-valid?'s null-handle check instead, per PLAN.md's
;; design: all of these checks are independent, not layered.

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

(define (node-append! seq item)
  (check-node-live! seq)
  (check-node-live! item)
  (assert (node-sequence? seq) "node-append!: not a sequence node" seq)
  (let ((status (fy_node_sequence_append (node-raw seq) (node-raw item))))
    (when (not (= status 0))
      (error "slibfyaml: fy_node_sequence_append failed" seq item))))
;; Append item (typically freshly built via document-create-scalar/
;; -sequence/-mapping) to the end of the seq sequence -- same as
;; alibfyaml's Append. Unlike document-insert-at!, item is attached
;; outright, not merged: fy_node_sequence_append's own header documents
;; no unref of it, so item is NOT consumed -- it remains a perfectly
;; usable node afterward, reading back exactly what was built.

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

(define (node-append-pair! map key value)
  (check-node-live! map)
  (check-node-live! key)
  (check-node-live! value)
  (assert (node-mapping? map) "node-append-pair!: not a mapping node" map)
  (let ((status (fy_node_mapping_append (node-raw map) (node-raw key) (node-raw value))))
    (when (not (= status 0))
      (error "slibfyaml: fy_node_mapping_append failed" map key value))))
;; Append a (key, value) pair (typically freshly built via
;; document-create-scalar/-sequence/-mapping) to the end of the map
;; mapping -- same as alibfyaml's Append_Pair. Unlike
;; document-insert-at!, key and value are attached outright, not
;; merged: fy_node_mapping_append's own header documents no unref of
;; either, so neither is consumed -- both remain usable afterward.

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

;;;; Required mapping access

(define (node-required map key)
  (let ((v (node-value map key)))
    (if (node-valid? v)
        v
        (raise-missing-key key (node-path map)))))
;; The value associated with Key, raising (exn slibfyaml missing-key)
;; -- rather than returning null-node -- if Map has no such key. Same
;; as alibfyaml's Required; node-value above already checks liveness
;; and mapping-kind, so this doesn't repeat either check.

(define (required-scalar map key)
  (let ((v (node-required map key)))
    (if (node-scalar? v)
        v
        (raise-data-error (string-append "key \"" key "\" is not a scalar value")
                           (node-path map)))))
;; Like node-required, but also confirms the found value is a scalar,
;; raising (exn slibfyaml data) -- not a bare assert -- if it's a
;; sequence/mapping instead: this is a malformed-*data* problem, not a
;; caller/programmer error the way calling e.g. node-scalar-value on a
;; non-scalar node is. Private to this module -- used by every
;; mapping-collapsed typed accessor below, same as alibfyaml's own
;; Required_Scalar.

;;;; Typed scalar accessors (YAML 1.2 core schema, plus alibfyaml's own
;;;; two documented extensions: "0b" binary integers, and "_" as a
;;;; digit separator strictly between two digits in any base) -- ported
;;;; from libfyaml-nodes.adb's private grammar helpers section. See
;;;; PLAN.md's "Typed scalar accessors" section for the schema
;;;; reference and the two extensions' rationale.
;;;;
;;;; libfyaml's core layer hands back scalars as plain text; it does
;;;; not implicitly resolve "8" to an integer or "true" to a boolean
;;;; the way a schema-aware loader would. Resolving that is this
;;;; module's job, same division of labor as alibfyaml's Ada.

(define (trimmed s)
  (let* ((len (string-length s))
         (start (let loop ((i 0))
                  (if (and (< i len) (char-whitespace? (string-ref s i)))
                      (loop (+ i 1))
                      i)))
         (end (let loop ((i len))
                (if (and (> i start) (char-whitespace? (string-ref s (- i 1))))
                    (loop (- i 1))
                    i))))
    (substring s start end)))

(define (strip-sign s)
  (if (and (> (string-length s) 0)
           (memv (string-ref s 0) '(#\+ #\-)))
      (substring s 1 (string-length s))
      s))

(define (dec-digit? c) (and (char>=? c #\0) (char<=? c #\9)))
(define (hex-digit? c)
  (or (dec-digit? c)
      (and (char>=? c #\a) (char<=? c #\f))
      (and (char>=? c #\A) (char<=? c #\F))))
(define (oct-digit? c) (and (char>=? c #\0) (char<=? c #\7)))
(define (bin-digit? c) (or (char=? c #\0) (char=? c #\1)))

;; Length of the maximal run starting at S[from] matching the grammar
;; `digit ('_' digit)*` under the given digit predicate (0 if S[from]
;; itself isn't a digit, or from is past S's end) -- the underscore is
;; accepted only strictly between two digits, never leading, trailing,
;; or doubled. The matched text (underscores included) is what
;; strip-underscores below then cleans up before handing the digits to
;; string->number -- this is what lets "1_000_000" or "0xFF_FF" through
;; as an extension without a separate validation pass.
(define (digit-run-length s from digit?)
  (let ((len (string-length s)))
    (if (or (>= from len) (not (digit? (string-ref s from))))
        0
        (let loop ((i (+ from 1)))
          (cond ((>= i len) (- i from))
                ((digit? (string-ref s i)) (loop (+ i 1)))
                ((and (char=? (string-ref s i) #\_)
                      (< (+ i 1) len)
                      (digit? (string-ref s (+ i 1))))
                 (loop (+ i 2)))
                (else (- i from)))))))

(define (digit-run? s digit?)
  (and (> (string-length s) 0)
       (= (digit-run-length s 0 digit?) (string-length s))))

;; "0b" (binary) is a documented extension beyond YAML 1.2 core schema,
;; accepted unconditionally rather than gated behind a schema-selection
;; flag -- see PLAN.md.
(define (integer-text? s)
  (let ((b (strip-sign s)))
    (cond ((and (>= (string-length b) 2) (string=? (substring b 0 2) "0x"))
           (digit-run? (substring b 2 (string-length b)) hex-digit?))
          ((and (>= (string-length b) 2) (string=? (substring b 0 2) "0o"))
           (digit-run? (substring b 2 (string-length b)) oct-digit?))
          ((and (>= (string-length b) 2) (string=? (substring b 0 2) "0b"))
           (digit-run? (substring b 2 (string-length b)) bin-digit?))
          (else (digit-run? b dec-digit?)))))

;; YAML 1.2 core schema float grammar: a required decimal digit run,
;; then an optional ".frac" (a digit required on both sides of the
;; dot -- bare ".5" or trailing "3." are not accepted), then an
;; optional exponent. No 0x/0o/0b handling here -- unlike
;; integer-text?, a based literal is never valid float grammar (e.g.
;; "0x1A" is Is_Integer but not Is_Float, confirmed against alibfyaml's
;; own test/scalars.yaml). A plain decimal integer (no dot, no
;; exponent) does count as valid float text, same as alibfyaml.
(define (float-text? s)
  (let* ((b (strip-sign s))
         (blen (string-length b)))
    (and (> blen 0)
         (let ((int-len (digit-run-length b 0 dec-digit?)))
           (and (> int-len 0)
                (let ((pos1 (if (and (< int-len blen) (char=? (string-ref b int-len) #\.))
                                 (let ((flen (digit-run-length b (+ int-len 1) dec-digit?)))
                                   (if (= flen 0) -1 (+ int-len 1 flen)))
                                 int-len)))
                  (and (>= pos1 0)
                       (let ((pos2 (if (and (< pos1 blen) (memv (string-ref b pos1) '(#\e #\E)))
                                        (let* ((p2 (+ pos1 1))
                                               (p3 (if (and (< p2 blen) (memv (string-ref b p2) '(#\+ #\-)))
                                                       (+ p2 1) p2))
                                               (elen (digit-run-length b p3 dec-digit?)))
                                          (if (= elen 0) -1 (+ p3 elen)))
                                        pos1)))
                         (and (>= pos2 0) (= pos2 blen))))))))))

(define (boolean-text? s)
  (or (member s '("true" "True" "TRUE"))
      (member s '("false" "False" "FALSE"))))

;; YAML 1.2 core schema null spellings. Deliberately excludes "": an
;; explicit quoted "" is a deliberate empty *string*, not null -- the
;; unquoted-omitted case ("key:" with nothing after) is handled
;; separately, by libfyaml's own fy_node_is_null, at the token level
;; rather than by text content.
(define (null-text? s)
  (or (string=? s "~") (string=? s "null") (string=? s "Null") (string=? s "NULL")))

(define (strip-underscores s)
  (let* ((len (string-length s))
         (buf (make-string len)))
    (let loop ((i 0) (j 0))
      (if (>= i len)
          (substring buf 0 j)
          (if (char=? (string-ref s i) #\_)
              (loop (+ i 1) j)
              (begin (string-set! buf j (string-ref s i))
                     (loop (+ i 1) (+ j 1))))))))
;; No srfi-1 filter/string->list dependency -- this module (like the
;; rest of slibfyaml) sticks to plain scheme + (chicken base), matching
;; the project's no-unnecessary-egg-dependencies stance (see
;; slibfyaml.egg's own (dependencies (chicken "5.4.0")) line).

;; S is already confirmed by integer-text? to match the grammar --
;; parses straight to a Scheme integer via string->number's explicit-
;; radix form (which, confirmed live, accepts a leading sign combined
;; with a radix argument directly, e.g. (string->number "-1A" 16) =>
;; -26, so no separate sign-then-reassemble step is needed the way
;; alibfyaml's Integer_Literal_Text rewrite for Ada's based-literal
;; syntax requires). No overflow case, unlike every one of alibfyaml's
;; three fixed-width Integer_Value/Long_Integer_Value/
;; Long_Long_Integer_Value -- CHICKEN's numeric tower auto-promotes to
;; bignums, so this one function covers arbitrarily large integers; see
;; PLAN.md's API surface sketch note on this collapse.
(define (parse-integer-text s)
  (let* ((sign? (and (> (string-length s) 0) (memv (string-ref s 0) '(#\+ #\-))))
         (sign (if sign? (substring s 0 1) ""))
         (unsigned (strip-underscores (if sign? (substring s 1 (string-length s)) s))))
    (cond ((and (>= (string-length unsigned) 2) (string=? (substring unsigned 0 2) "0x"))
           (string->number (string-append sign (substring unsigned 2 (string-length unsigned))) 16))
          ((and (>= (string-length unsigned) 2) (string=? (substring unsigned 0 2) "0o"))
           (string->number (string-append sign (substring unsigned 2 (string-length unsigned))) 8))
          ((and (>= (string-length unsigned) 2) (string=? (substring unsigned 0 2) "0b"))
           (string->number (string-append sign (substring unsigned 2 (string-length unsigned))) 2))
          (else (string->number (string-append sign unsigned) 10)))))

;; S is already confirmed by float-text? to match the grammar --
;; strip-underscores then hand straight to string->number, whose
;; syntax otherwise already matches (sign, digit run, optional
;; ".frac", optional e/E exponent). May return +inf.0/-inf.0 for a
;; literal that overflows a double's finite range (confirmed live: e.g.
;; (string->number "1e400") => +inf.0, no exception) -- the caller
;; (float-value-of-node below) checks for that explicitly, since
;; CHICKEN flonums are IEEE double (matching alibfyaml's Long_Float,
;; the widest of its Float_Value/Long_Float_Value pair), so this one
;; function also covers what alibfyaml needs two for, but an overflow
;; check is still needed at the one width that remains.
(define (parse-float-text s)
  (string->number (strip-underscores s)))

(define (node-null-value? n)
  (check-node-live! n)
  (or (fy_node_is_null (node-raw n))
      (and (node-scalar? n) (null-text? (trimmed (node-scalar-value n))))))
;; True if N is an empty/omitted scalar (fy_node_is_null resolves this
;; -- confirmed against the installed libfyaml header that a NULL node
;; argument itself also returns true, so this needs no extra
;; node-valid? guard) OR a scalar whose text is a YAML 1.2 null
;; spelling. Same as alibfyaml's Is_Null_Value; unlike node-integer?/
;; node-float?/node-boolean? below, doesn't require N to already be a
;; scalar (mirrors Is_Null_Value's own precondition, which is just
;; Is_Valid, not Is_Valid-and-then-Is_Scalar).

(define (node-integer? n) (integer-text? (trimmed (node-scalar-value n))))
(define (node-float? n) (float-text? (trimmed (node-scalar-value n))))
(define (node-boolean? n) (boolean-text? (trimmed (node-scalar-value n))))
;; Non-raising shape predicates -- e.g. for deciding whether a list
;; element is a plain string or some other scalar shape before
;; committing to a conversion. node-scalar-value already enforces N is
;; a scalar (via its own assert), matching alibfyaml's
;; Is_Valid-and-then-Is_Scalar precondition on Is_Integer/Is_Float/
;; Is_Boolean.

(define (integer-value-of-node n)
  (let ((text (trimmed (node-scalar-value n))))
    (if (integer-text? text)
        (parse-integer-text text)
        (raise-data-error (string-append "not a valid integer: \"" text "\"")
                           (node-path n)))))

(define (float-value-of-node n)
  (let ((text (trimmed (node-scalar-value n))))
    (if (float-text? text)
        (let ((v (parse-float-text text)))
          (if (or (= v +inf.0) (= v -inf.0))
              (raise-data-error (string-append "float out of range: \"" text "\"")
                                 (node-path n))
              v))
        (raise-data-error (string-append "not a valid float: \"" text "\"")
                           (node-path n)))))

(define (boolean-value-of-node n)
  (let ((text (trimmed (node-scalar-value n))))
    (cond ((member text '("true" "True" "TRUE")) #t)
          ((member text '("false" "False" "FALSE")) #f)
          (else (raise-data-error (string-append "not a valid boolean: \"" text "\"")
                                   (node-path n))))))
;; Raise (exn slibfyaml data) if the scalar text doesn't match the
;; target type's grammar (including a float literal that overflows a
;; double to infinity) -- same as alibfyaml's Data_Error, plus the
;; automatic 'path field raise-data-error itself attaches (see
;; slibfyaml.scm). Each assumes N is already a scalar, same precondition
;; as node-integer?/node-float?/node-boolean? above -- node-scalar-value
;; enforces it.

;; A unique sentinel, never `eq?` to anything a caller could pass, used
;; below to tell "key/default not supplied" apart from any real
;; argument value (including #f, which is a legitimate default) --
;; CHICKEN's #!optional has no built-in supplied-p the way some other
;; Lisps do.
(define unsupplied (list 'unsupplied))

(define (typed-mapping-value map key convert)
  (convert (required-scalar map key)))
;; Required (Map, Key) form shared by every typed accessor below:
;; (exn slibfyaml missing-key) if Key is absent, (exn slibfyaml data)
;; if present but not a scalar (both via required-scalar) or scalar but
;; grammar-malformed (via convert).

(define (typed-mapping-value/default map key default convert)
  (let ((v (node-value map key)))
    (cond ((not (node-valid? v)) default)
          ((not (node-scalar? v))
           (raise-data-error (string-append "key \"" key "\" is not a scalar value")
                              (node-path map)))
          (else (convert v)))))
;; Optional (Map, Key, Default) form: Default only substitutes for
;; Key's *absence* -- a present-but-malformed or present-but-non-scalar
;; value still raises, never silently falls back to Default, per
;; alibfyaml's explicit design rule that a default must never mask a
;; malformed value.

(define (node-integer-value n #!optional (key unsupplied) (default unsupplied))
  (cond ((eq? key unsupplied) (integer-value-of-node n))
        ((eq? default unsupplied) (typed-mapping-value n key integer-value-of-node))
        (else (typed-mapping-value/default n key default integer-value-of-node))))

(define (node-float-value n #!optional (key unsupplied) (default unsupplied))
  (cond ((eq? key unsupplied) (float-value-of-node n))
        ((eq? default unsupplied) (typed-mapping-value n key float-value-of-node))
        (else (typed-mapping-value/default n key default float-value-of-node))))

(define (node-boolean-value n #!optional (key unsupplied) (default unsupplied))
  (cond ((eq? key unsupplied) (boolean-value-of-node n))
        ((eq? default unsupplied) (typed-mapping-value n key boolean-value-of-node))
        (else (typed-mapping-value/default n key default boolean-value-of-node))))
;; Three arities each, dispatched on which #!optional args were
;; actually supplied (CHICKEN's stand-in for Ada's overload
;; resolution): (node-T-value n) is the per-node form (Pre => Is_Scalar,
;; enforced by node-scalar-value inside *-value-of-node); (node-T-value
;; map key) and (node-T-value map key default) are the mapping-
;; collapsed required/optional forms. No node-string-value(n) --
;; node-scalar-value already covers that case; alibfyaml itself has no
;; bare Node overload of String_Value either, only the (Map, Key) forms
;; below.

(define (node-string-value map key #!optional (default unsupplied))
  (if (eq? default unsupplied)
      (typed-mapping-value map key node-scalar-value)
      (typed-mapping-value/default map key default node-scalar-value)))
;; String_Value never rejects text on grammar grounds (any scalar text
;; is valid), unlike its numeric/boolean siblings -- the only ways to
;; get (exn slibfyaml data) here are the shared non-scalar-value check
;; and (exn slibfyaml missing-key) for the required form's absent key.

) ;; module
