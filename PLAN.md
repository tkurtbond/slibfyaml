# slibfyaml design plan

A CHICKEN Scheme 5 binding to libfyaml's core parser/emitter/document
API, adapting the design of the `alibfyaml` Ada binding
(`~/Repos/Ada/alibfyaml`) to Scheme's runtime model. This document is
the up-front design plan, written before any code exists. Once
implementation starts, keep this file current the way `alibfyaml`'s own
`PLAN.md` does: append design decisions and confirmed findings to the
relevant section rather than starting a new document, and strike
through open questions as they get resolved.

## Motivation

Two YAML eggs already exist for Chicken (`yaml`, binding real libyaml;
`libyaml`, actually binding libfyaml despite the name — see this
project's sibling comparison note). Both take the same basic shape:
parse the whole document into plain Scheme data in one call
(`yaml-load` / `yaml->ss`), and hand the caller a self-contained value
with no further ties to the library. That's the right tool for "read a
small config file into an alist," but it has no lazy access, no path
queries, and no way to mutate a parsed tree without walking it into an
entirely separate build/emit pass.

`alibfyaml` demonstrates the other shape for the same underlying C
library: a `Document` owns a parsed/built libfyaml tree, and `Node` is a
cheap, non-owning handle into it, navigated with predicates and
accessors (`Kind`, `Item`, `Value`, `By_Path`, ...) and mutated in
place (`Create_Scalar`/`Append`/`Insert_At`). `slibfyaml` ports that
shape to Chicken: same handle-over-a-C-owned-tree model, same function
surface, same typed-scalar resolution against YAML 1.2's core schema —
adapted for a garbage-collected host with no RAII.

## Design goals

- Match `alibfyaml`'s API shape and scope closely enough that someone
  who knows one can read the other — same node kinds, same typed-scalar
  accessor set, same path-lookup semantics, same multi-document
  streaming behavior (including its documented "does not recover from
  a parse error" limitation).
- Idiomatic Scheme naming and idiomatic Scheme conventions
  (kebab-case, `?` predicates, `!` for anything that mutates state or
  frees a resource), not a mechanical transliteration of Ada
  identifiers.
- Exploit what CHICKEN offers that Ada doesn't need translating around:
  a single numeric tower (no `Integer`/`Long_Integer`/`Long_Long_Integer`
  split — see "Typed scalar accessors" below), conditions instead of a
  fixed exception hierarchy, optional/keyword arguments instead of
  overload sets.
- Be honest about what CHICKEN's GC does *not* give us for free
  (deterministic destruction, a non-moving heap) and design the
  buffer-lifetime story around that from the start, rather than
  discovering the equivalent of `alibfyaml`'s `Document_Stream`
  buffer-lifetime bug (see its PLAN.md) after the fact.

## Scope: same exclusions as `alibfyaml`

Not covering, for the same reasons:

- `fy_generic` (the ergonomic dict/list-like sum-type builder layer):
  C11 `_Generic`/variadic macros, no plain C-callable entry point to
  bind from any FFI, CHICKEN's included.
- Reflection (typed YAML <-> C struct serdes via libclang/packed
  metadata): no Scheme-struct analogue to target.
- `scanf`/`printf`-style variadic entry points
  (`fy_document_scanf`, `fy_node_buildf`, ...): CHICKEN's
  `foreign-lambda` can't call C varargs functions generically either.
  Use the typed navigation API instead.

## Target libfyaml version

`alibfyaml`'s README warns that a system-packaged libfyaml (labeled
`0.8`) might be a much older ABI than the 1.0-beta1 API it targets, and
walks through building from source as the fallback. Checked directly
on this machine before writing this plan (same machine `alibfyaml`
develops against):

```
$ pkg-config --modversion libfyaml
0.8
```

Every C symbol `alibfyaml`'s thin binding layer imports was confirmed
present in `/usr/include/libfyaml.h` on this machine (`grep` for each
of the ~30 exported names — `fy_document_build_from_string`,
`fy_node_mapping_iterate`, `fy_diag_errors_iterate`, etc. — all
present). This matches `alibfyaml`'s own confirmed finding in its
`AGENTS.md`: the Fedora package labeled `0.8-9.fc44` already exposes
the 1.0-beta1 API surface both bindings need. **Plan to target the
system `pkg-config libfyaml` directly** rather than requiring a
from-source build as a precondition; fall back to `alibfyaml`'s
build-from-source recipe only if a future `chicken-install` on some
other machine turns up missing symbols. Verify with `nm -D` against
the actual `.so`, not just the header, before relying on a symbol —
the header being present doesn't guarantee the installed shared
library exports it (unlikely to diverge, but cheap to check).

## Naming

- Egg name: `slibfyaml` (matches this repository).
- Scheme module family, mirroring `alibfyaml`'s child-package layout via
  CHICKEN 5's list-style module names (the same mechanism the existing
  `libyaml` egg uses for its own `(libfyaml yaml2ss)` /
  `(libfyaml if)` submodules):
  - `(fyaml thin)` — raw FFI imports (≈ `Libfyaml.Thin`)
  - `(fyaml)` — condition types (≈ top-level `Libfyaml`)
  - `(fyaml nodes)` — `node` (≈ `Libfyaml.Nodes`)
  - `(fyaml documents)` — `document` (≈ `Libfyaml.Documents`)
  - `(fyaml documents streams)` — multi-document streaming
    (≈ `Libfyaml.Documents.Streams`)
- Deliberately *not* named `libfyaml` or `libyaml` as a Scheme module,
  to avoid any confusion with the existing (differently-scoped, oddly-
  named) `libyaml` egg that also binds libfyaml.
- Open question: is `fyaml` too easy to misread as `yaml`? Alternative:
  `slibfyaml` itself as the top module name, at the cost of a longer
  `(import (slibfyaml nodes))` everywhere. Leaning toward `fyaml` —
  flag for confirmation before writing code.

## C function surface

Bind exactly the set `alibfyaml`'s `libfyaml-thin.ads` binds — it's
already a carefully scoped-down list (the thick layer's actual call
set, not the full library speculatively), and every one of those
symbols was independently confirmed present in the local libfyaml
header above:

- **Document lifecycle**: `fy_document_build_from_string`,
  `fy_document_build_from_file`, `fy_document_destroy`,
  `fy_document_root`, `fy_document_set_root`, `fy_document_insert_at`,
  `fy_document_get_diag`, `fy_document_resolve`
- **Streaming parser**: `fy_parser_create`, `fy_parser_destroy`,
  `fy_parser_set_string`, `fy_parser_set_input_file`,
  `fy_parse_load_document`, `fy_parser_set_diag`
- **Node predicates/type**: `fy_node_get_type`, `fy_node_is_null`,
  `fy_node_get_style`, `fy_node_get_tag`
- **Location**: `fy_node_get_scalar_token`, `fy_token_start_mark`
- **Scalar access/build**: `fy_node_get_scalar`,
  `fy_node_create_scalar_copy`, `fy_node_create_sequence`,
  `fy_node_create_mapping`
- **Sequence access**: `fy_node_sequence_item_count`,
  `fy_node_sequence_get_by_index`, `fy_node_sequence_append`,
  `fy_node_sequence_iterate`
- **Mapping access**: `fy_node_mapping_item_count`,
  `fy_node_mapping_lookup_value_by_string`, `fy_node_mapping_append`,
  `fy_node_mapping_iterate`, `fy_node_pair_key`, `fy_node_pair_value`
- **Path**: `fy_node_by_path`, `fy_node_get_path`
- **Emit**: `fy_emit_document_to_string`, `fy_emit_document_to_file`
- **Diagnostics**: `fy_diag_create`, `fy_diag_destroy`,
  `fy_diag_set_collect_errors`, `fy_diag_got_error`,
  `fy_diag_errors_iterate`
- **libc**: `free` (to release libfyaml's own `malloc`'d out-strings,
  e.g. from `fy_emit_document_to_string` / `fy_node_get_path`)

Same constraint Ada hit applies identically in CHICKEN: `fy_node_is_scalar`
/ `_is_sequence` / `_is_mapping` / `_is_alias` are `static inline` header
wrappers, not exported symbols — `foreign-lambda` can't bind them any
more than `pragma Import` could. Reimplement them in `(fyaml nodes)` by
comparing `fy_node_get_type`'s result, exactly as `alibfyaml` does.

## Struct field access: prefer inline C snippets over hand-mirrored structs

`alibfyaml` hand-mirrors two C structs as Ada records with `Convention
=> C` (`Fy_Parse_Cfg`, `Fy_Diag_Error`), which works but ties the
binding to those structs' exact field order/padding as of the libfyaml
version it was written against — a real ABI-drift risk across libfyaml
releases.

The existing `yaml` Chicken egg already sidesteps this for the real
libyaml library: rather than mirroring `yaml_event_t`'s layout, it
defines tiny helper functions with `foreign-lambda*`, e.g.:

```scheme
(define scalar-anchor (foreign-lambda* c-string
                                       ((yaml_event_t e))
                                       "C_return(e->data.scalar.anchor);"))
```

letting the C compiler compute the real field offset at build time
against whatever `yaml.h` is actually installed. **Use the same idiom
here** for `Fy_Diag_Error` field access (`msg`, `file`, `line`,
`column`) and for building an `Fy_Parse_Cfg` to pass by pointer (a
small `foreign-lambda*` that mallocs one, sets `.flags`/`.diag`, and
returns the pointer, freed after the call) — never a hand-written
CHICKEN record type standing in for the C struct's memory layout.
This removes an entire class of bug `alibfyaml` has to guard against
by pinning to a specific header snapshot.

## Data model

| Ada (`alibfyaml`) | Chicken (`slibfyaml`) |
|---|---|
| `type Node is tagged private` wrapping `Thin.Fy_Node` | `(define-record-type node (make-node handle) node? (handle node-handle))` wrapping a raw `c-pointer` |
| `Null_Node : constant Node` | `fyaml-null-node` (a distinguished `node` wrapping a null pointer) |
| `type Document is tagged limited private` (RAII, `Ada.Finalization.Limited_Controlled`) | `(define-record-type document ...)` wrapping the `Fy_Document` pointer + owned-buffer state; see Memory model below for how "RAII" is approximated |
| `Wrap`/`Raw` bridge functions (binding-internal) | Same idea: `node-wrap`/`node-raw`, `document-wrap`/`document-raw`, exported only from `(fyaml nodes)`/`(fyaml documents)` for `(fyaml documents streams)` to use, not part of the public API |
| Overloaded `Integer_Value`/`Long_Integer_Value`/`Long_Long_Integer_Value` | **Collapses to one `node-integer-value`.** CHICKEN's numeric tower auto-promotes to bignums; there is no fixed-width integer type a caller needs to pre-choose the way Ada's static typing forces. Same collapse for `Float_Value`/`Long_Float_Value` → one `node-float-value` (CHICKEN flonums are IEEE double already, matching Ada's `Long_Float`, so nothing is lost). This is a genuine simplification over the Ada API, not a gap. |
| `Node_Kind` enum (`Scalar_Node`, `Sequence_Node`, `Mapping_Node`) | `(node-kind n)` returns a symbol: `'scalar`, `'sequence`, `'mapping` |
| `Node_Location` record (`Line`, `Column`) | Two values via `(node-location n)` → `(values line column)`, or a simple pair — decide during implementation; leaning toward two `values` to avoid allocating a throwaway record for something read once per error site |

## Memory model — the central design problem

This is the section most likely to grow as implementation surfaces
real bugs, the same way `alibfyaml`'s PLAN.md accumulated three
confirmed lifetime bugs (`Parse_Common` double-free,
`Document_Stream` buffer lifetime, `Insert_At` use-after-free) over
its development. Plan for that pattern here too: verify lifetime claims
live (under valgrind) rather than by inspection, same rule as
`alibfyaml`'s `AGENTS.md` states.

### Document ownership: no RAII, so what replaces it?

Ada's `Document` is `Ada.Finalization.Limited_Controlled`: going out of
scope deterministically calls `Finalize`, which frees the libfyaml
document. CHICKEN has no deterministic destructors. Two mechanisms,
used together:

1. **`set-finalizer!` as a GC backstop** — attach a finalizer to the
   `document` record that calls `fy_document_destroy` (and frees any
   owned buffer — see below) if the caller never explicitly cleaned up.
   This is *not* a substitute for explicit cleanup: CHICKEN's finalizers
   run at an unpredictable point (next GC that notices the object is
   unreachable), so a program that parses many documents in a tight
   loop without explicit cleanup can accumulate a large amount of
   unfreed C-side memory before a GC catches up — worse than Ada, where
   scope exit is immediate.
2. **Explicit `document-destroy!`, and a `with-document`-style
   combinator built on `dynamic-wind`** analogous to
   `call-with-input-file`, e.g.:

   ```scheme
   (with-document (doc (fyaml-parse-file "config.yaml"))
     (node-value (document-root doc) "server"))
   ```

   as the recommended idiom for anything that isn't itself
   long-lived. `document-destroy!` must be idempotent (guard on a
   "already destroyed" flag in the record) since both the explicit call
   and, later, the finalizer may otherwise both fire — mirroring the
   double-free class of bug `alibfyaml` hit in `Parse_Common` (there,
   from a refactor moving a call from a statement into a declarative
   part bypassing an exception handler; here, from two independent
   cleanup paths on the same handle). **Every mutating/destroying
   operation must leave the record in a state where a second call
   raises a clear error or is a safe no-op, never a second `free`.**

### Node validity after its Document is gone

Ada's contract is purely documentational: "a Node is valid as long as
its Document hasn't been finalized," enforced nowhere except by the
caller not misusing it. CHICKEN can do slightly better cheaply: give
each `document` record a mutable "live?" flag, and have every `node`
record carry a reference back to the `document` it came from (not just
the raw pointer). `node` accessors can then check
`(document-live? owning-doc)` before touching the raw handle and raise
a clear condition (`(exn fyaml use-after-free)`, or similar) instead of
segfaulting or reading freed memory on a use-after-destroy. This is
strictly more defensive than `alibfyaml`'s Ada contract (which relies
on `-gnata` preconditions checking `Is_Valid` — null-check only, not a
"my owner is gone" check) and costs one extra field + one branch per
accessor call. Worth doing given how much of `alibfyaml`'s bug history
is exactly this class of problem; revisit if it turns out to be a real
performance concern (unlikely — these are FFI calls already, the
overhead is noise).

### The buffer-lifetime problem: worse in Chicken than it was in Ada

This is the single most important thing to get right before writing
any parsing code, and the main reason this plan calls it out ahead of
implementation rather than letting it surface as a bug later:

libfyaml's core layer is zero-copy wherever it can be — a document
built from `fy_document_build_from_string` keeps its plain-scalar
`fy_node_get_scalar` results as spans directly into the *caller's own
input buffer*, for the entire life of the document, not just for the
duration of the parse call. `alibfyaml` ran into a real, confirmed
(valgrind-caught) use-after-free from this: a `Document` drawn from a
`Document_Stream` opened with `Open_String` shared its scalars'
backing buffer with the *stream* object rather than owning a reference
to it, so destroying the stream while such a Document was still alive
silently read freed memory. Ada fixed it with a small reference-counted
`Buffer_Ref`/`Buffer_Cell` shared between whichever owners need the
same buffer alive.

**In CHICKEN, the equivalent naive port is broken from the very first
`document-parse-string` call, not just in a niche streaming case**, for
two independent reasons:

1. `foreign-lambda`'s ordinary C-string argument marshaling
   (`c-string`, `nonnull-c-string`, etc.) produces a buffer whose
   validity is only guaranteed *for the duration of that one call* —
   there is no implicit promise it stays valid afterward, unlike
   passing a Scheme string's address directly.
2. Even if a raw pointer into a Scheme string's byte content were
   taken instead, CHICKEN's default heap is a **copying/moving
   collector** — a string object can be relocated to a different
   address by a later GC even while the Scheme-level string is still
   reachable, which a raw C pointer captured earlier does not track.

So this binding must **never hand libfyaml a pointer into
CHICKEN-managed string storage for anything that outlives the call**.
The fix, decided here rather than discovered later:

- `document-parse-string`/`document-stream-open-string` always
  **copy** the input into a `malloc`'d C buffer *we* allocate and own
  (a small `foreign-lambda*` doing `malloc` + `memcpy` from the
  Scheme string's bytes), store that pointer in the `document` (or
  `document-stream`) record, and free it exactly once, in
  `document-destroy!`/the finalizer — using the same reference-counted
  sharing `alibfyaml`'s `Buffer_Ref` uses for the one case where a
  buffer really is shared across more than one owner (a
  `document-stream` opened from a string, and every `document` drawn
  from it via `document-stream-next!`).
- `document-parse-file`/`document-stream-open-file` need no such
  buffer: libfyaml reads/mmaps the file itself, matching `alibfyaml`'s
  confirmed finding that `Open_File` has no equivalent hazard.
- This trades away true zero-copy parsing for a single `memcpy` per
  parse in exchange for never having to reason about Scheme's GC
  moving memory out from under a live C-side pointer. `alibfyaml`
  briefly considered a zero-copy `Create_Scalar` and explicitly
  decided against pursuing it (see its PLAN.md, "Zero-copy
  Create_Scalar — decided not to pursue") for related reasons even in
  Ada, which doesn't have a moving collector to begin with — a strong
  signal this binding shouldn't attempt zero-copy from Scheme storage
  at all.

### Insert_At-style consumption contracts

`alibfyaml`'s `Insert_At` unconditionally consumes its `N` argument
(unref'd by libfyaml on both success and failure) and the binding
responds by nulling `N` out unconditionally, discovered as a bug when
an earlier version only did this on failure. Port the same
unconditional-invalidation discipline to `document-insert-at!`: mark
the passed-in `node` record as consumed (e.g., null its handle field
out, or flip a "consumed?" flag checked by every subsequent accessor)
regardless of the C call's return code, and document, for every
mutating procedure added later, exactly what happens to each `node`/
`document` argument on both outcomes — the same rule `alibfyaml`'s
`AGENTS.md` states as a standing conventions item.

## Error handling

Chicken condition types, matching the five Ada exceptions and the
condition-tagging convention already used by the two existing Chicken
YAML eggs (`(exn <lib> <procedure>)`-style composite kinds):

- `(exn fyaml parse)` — parse failure. Message formatted the same
  gcc-style way `alibfyaml`'s `Parse_Error` is
  (`file:line:column: error: message`, one line per collected
  diagnostic, via `fy_diag_errors_iterate`), a format `alibfyaml`
  arrived at deliberately (see its PLAN.md, "Parse_Error message
  reformatted to gcc diagnostic style") — no reason to make a
  different choice here.
- `(exn fyaml emit)` — emit failure.
- `(exn fyaml missing-key)` — required mapping key absent.
- `(exn fyaml data)` — scalar present but not resolvable as the
  requested typed-accessor's type.
- `(exn fyaml resolve)` — `document-resolve!` failure (e.g. a
  merge-key cycle). Same caveat `alibfyaml` documents: libfyaml doesn't
  say how much resolved before failing, so treat the document as
  unreliable afterward, not as cleanly rolled back.

Each condition carries `'message`, and `parse`/`resolve` additionally
carry structured fields (`'file`, `'line`, `'column`) alongside the
formatted message, so a caller can act on them programmatically
instead of re-parsing the message string — the existing `yaml` egg
already does this (`'line`/`'column`/`'problem`/`'context` on its parse
exception), a convention worth keeping.

## Typed scalar accessors

Same schema as `alibfyaml`: YAML 1.2's
[core schema](https://yaml.org/spec/1.2.2/#103-core-schema) for
null/bool/int/float, plus the same two deliberate, documented
extensions beyond it:

- `0b` binary integers (YAML 1.1, not core-schema, accepted
  unconditionally rather than gated behind a schema-selection flag).
- `_` as a digit separator in decimal/hex/octal/binary integers and in
  each part of a float, strictly between two digits only.

`node-is-null-value?`/`node-null-value?` resolves the same two cases
`alibfyaml`'s `Is_Null_Value` does: an empty/omitted scalar
(unambiguous at the grammar level, libfyaml itself resolves this) and a
scalar whose text is a YAML 1.2 null spelling (`~`, `null`, `Null`,
`NULL`) — explicitly *not* a quoted `""`, which is a deliberate empty
string.

Accessors, collapsing Ada's per-width overload sets as noted above:

- `node-integer-value`, `node-float-value`, `node-boolean-value`,
  `node-string-value` (≈ `Scalar_Value`, just named for consistency
  with the typed family) — raise `(exn fyaml data)` on a mismatch.
- `node-integer?`, `node-float?`, `node-boolean?` — non-raising shape
  predicates, same purpose as Ada's (deciding a scalar's shape before
  committing to a conversion).
- Mapping-collapsed forms: `(node-integer-value map key)` /
  `(node-integer-value map key default)` and the same pattern for
  `float`/`boolean`/`string`, using CHICKEN's `#!optional` rather than
  Ada's required-vs-optional overload pair. Required form raises
  `(exn fyaml missing-key)` if absent, `(exn fyaml data)` if present
  but malformed; supplying `default` only substitutes for absence, per
  `alibfyaml`'s explicit design rule that a default must never mask a
  malformed value.

## API surface sketch

Organized the same way `alibfyaml`'s `Libfyaml.Nodes`/`Libfyaml.Documents`
are; exact signatures to firm up during implementation, not frozen here.

```scheme
;; (fyaml documents)
(document-parse-string string #!optional (resolve-anchors? #t))
(document-parse-file path #!optional (resolve-anchors? #t))
(document-resolve! doc)
(document-root doc)                      ; -> node
(document-set-root! doc n)
(document-insert-at! doc path n)         ; consumes n, see Memory model
(document-create-scalar doc value)       ; -> node
(document-create-sequence doc)           ; -> node
(document-create-mapping doc)            ; -> node
(document->yaml-string doc #!optional flags)
(document-write-to-file! doc path #!optional flags)
(document-destroy! doc)                  ; explicit, idempotent
(with-document (doc expr) body ...)      ; dynamic-wind combinator

;; (fyaml nodes)
(node-valid? n) (fyaml-null-node)
(node-kind n)                            ; 'scalar | 'sequence | 'mapping
(node-scalar? n) (node-sequence? n) (node-mapping? n)
(node-null-value? n)
(node-scalar-value n)
(node-has-location? n) (node-location n) ; -> (values line column)
(node-integer? n) (node-float? n) (node-boolean? n)
(node-integer-value n) (node-float-value n) (node-boolean-value n)
(node-length n) (node-item n index)      ; 1-based
(node-append! seq item)
(node-iterate seq visit-proc)
(node-value map key) (node-has-key? map key) (node-required map key)
(node-append-pair! map key value)
(node-iterate map visit-proc)            ; overload on node-kind, or
                                          ; split as node-iterate-pairs
(node-integer-value map key) (node-integer-value map key default)
;; ... float/boolean/string, same pattern
(node-by-path n path) (node-path n)
(node-alias? n) (node-tag n)

;; (fyaml documents streams)
(document-stream-open-string string)
(document-stream-open-file path)
(document-stream-has-next? stream)
(document-stream-next! stream)           ; -> document
```

`node-iterate` overloading on sequence-vs-mapping via a single name
(dispatching on `node-kind` internally, visitor arity implied by kind)
vs. two distinct names (`node-iterate-items` / `node-iterate-pairs`) is
an open question — Scheme has no static arity-based overload
resolution the way Ada's two `Iterate` procedures get resolved by
parameter profile, so this needs either a runtime kind check or
separate names. Leaning toward separate names for clarity at the call
site; revisit once real call sites exist.

## Multi-document YAML streams

Same split `alibfyaml` settled on: `document-parse-string`/
`document-parse-file` always mean "exactly one document," silently
parsing only the first of a multi-document input (matching what the
underlying `fy_document_build_from_string`/`_file` do) — use
`document-stream-*` for anything that might hold more than one.

Carry forward, rather than re-discover, `alibfyaml`'s confirmed
finding that **a stream does not recover from a parse error**:
libfyaml's streaming parser cannot resync past a malformed document to
reach further ones in the same stream, confirmed against libfyaml
directly including that an explicit parser reset does not restore
usable input state. After a `(exn fyaml parse)` from
`document-stream-next!`, treat the stream as exhausted:
`document-stream-has-next?` should report a clean `#f` rather than
raising again, even though the underlying input may textually contain
more documents after the malformed one. (Ada's own binding got this
wrong once — raising `Libfyaml.Parse_Error` a second time, quoting the
first error's now-stale message — before fixing it; no reason to
re-introduce that bug here by not planning for it up front.)

## Testing plan

Port `alibfyaml`'s one-file-per-concern structure, adapted to
whatever CHICKEN test convention this project settles on (plain
`assert` + `ok`/`FAIL` printouts matching `alibfyaml`'s own style for
consistency across the user's projects, or the `test` egg — decide
before writing the first test file):

- `test-quickstart` — parse a small config, read a nested value, emit
  it back out (≈ `alibfyaml`'s port of libfyaml's own
  `examples/quick-start.c`).
- `test-sequence`, `test-scalars` (exhaustive typed-accessor coverage,
  including the two schema extensions and their edge cases —
  leading/trailing/doubled `_`, etc.), `test-navigate`,
  `test-streams` (including a mid-stream parse error case),
  `test-mutate` (`document-insert-at!`'s success and failure
  outcomes for the node passed in), `test-anchors`, `test-parse-errors`,
  `test-location`, `test-path`.
- **Run anything touching document/node lifetime under valgrind**
  before considering it done — not optional polish, per `alibfyaml`'s
  own experience that every real lifetime bug it found surfaced as a
  test that *passed* while quietly reading freed or premature memory,
  caught only by valgrind. CHICKEN binaries compiled with `csc` are
  ordinary native executables; valgrind works on them the same way it
  does on the Ada tests.
- Specifically write a `test-buffer-lifetime` case exercising exactly
  the scenario `alibfyaml` found broken (a document drawn from a
  string-backed stream outliving something), even though the design
  above (always copy, refcount only where genuinely shared) is meant
  to prevent it by construction — confirm it live rather than trusting
  the design on paper, per this project's own stated principle above.

## Build/packaging

- `slibfyaml.egg` — CHICKEN 5 egg-information format, `extension`
  component(s) for `fyaml`/`fyaml.thin`/`fyaml.nodes`/
  `fyaml.documents`/`fyaml.documents.streams`, linking via
  `pkg-config libfyaml` (mirroring how other C-binding eggs in the
  CHICKEN ecosystem express link flags — confirm exact `.egg`
  csc-options syntax against a recent binding egg before writing this,
  rather than guessing).
- No C headers to compile (pure FFI import layer, same as
  `alibfyaml`) — only the linker needs to find `libfyaml.so`.

## Open questions

- Module naming: `(fyaml ...)` vs. `(slibfyaml ...)` — see Naming
  above.
- License: `alibfyaml` currently has none chosen either; the two
  existing Chicken YAML eggs are BSD-style (`yaml`) and MIT
  (`libyaml`). Pick one before the first public release, doesn't block
  design/implementation.
- `node-iterate` naming split (single overloaded name vs.
  `node-iterate-items`/`node-iterate-pairs`) — see API surface sketch.
- Whether to also offer an optional "materialize to plain Scheme data"
  convenience layer on top of the handle-based core (bridging back
  toward the `yaml`/`libyaml` eggs' value-based style for callers who
  just want a config file as an alist) — worth doing once the core is
  solid, but explicitly **not** a Phase 1 goal; the whole point of this
  egg is the handle/tree model the other two eggs don't offer.
- Whether `document-live?`/owner-tracking on every `node` (the extra
  defensiveness beyond what `alibfyaml`'s Ada contract provides,
  described in Memory model above) is worth its complexity once real
  usage patterns exist, or whether it's premature and the simpler
  Ada-equivalent "document your contract, don't enforce it" approach
  is enough for a first release.
- CHICKEN 4 support: not planned. The `yaml` egg supports both via
  `cond-expand`; this project targets CHICKEN 5.4.0 only unless a
  concrete need for 4 shows up.

## Phased roadmap

1. **Skeleton**: `.egg` file, `(fyaml thin)` with the full confirmed
   C function list bound (no logic yet), builds and links against
   system `pkg-config libfyaml`.
2. **Read-only parse + navigate**: `document-parse-string`/
   `-parse-file` (with the copy-always buffer strategy from day one,
   not retrofitted), `document-root`, `node-kind`/predicates,
   `node-scalar-value`, `node-length`/`node-item`, `node-value`/
   `node-has-key?`, `node-iterate` (both kinds), `node-by-path`/
   `node-path`. Enough to port `test-quickstart` and `test-navigate`.
3. **Typed scalars**: the full `node-integer-value`/etc. family, core
   schema + the two extensions, `test-scalars` exhaustive coverage.
4. **Build + emit + mutate**: `document-create-*`, `document-set-root!`,
   `document-insert-at!` (with unconditional-consumption discipline),
   `node-append!`/`node-append-pair!`, `document->yaml-string`/
   `-write-to-file!`. `test-mutate`.
5. **Anchors/resolve**: `document-resolve!`, `node-alias?`, `node-tag`,
   `resolve-anchors?` on parse. `test-anchors`.
6. **Multi-document streaming**: `(fyaml documents streams)`, the
   no-recovery-after-parse-error behavior, buffer-sharing via the
   refcounted-copy design. `test-streams`, `test-buffer-lifetime`.
7. **Diagnostics polish**: gcc-style `Parse_Error` formatting,
   `node-location`/`node-has-location?`, `test-parse-errors`/
   `test-location`.
8. **Packaging**: finalize `.egg` metadata, license, README examples
   matching the finished API, submit to CHICKEN's egg index if
   desired.

Each phase should leave the tree in a state where its own test file(s)
pass under valgrind before moving to the next phase — not deferred to
a final polish pass, per the lesson `alibfyaml`'s own history already
paid for once.
