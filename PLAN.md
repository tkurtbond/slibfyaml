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

`slibfyaml` also needs the other eggs' "just give me plain Scheme data"
entry point — not everyone navigating a config file wants to hold a
`document` open and walk `node` handles — but without `yaml-load`'s
single-document limitation. Since the handle/tree core can already
decode any node (whole document or not), and multi-document streaming
is already part of the plan, the value-materializing API in this egg is
a thin convenience layer built *on top of* the handle-based core rather
than a second, independent parser — see "Value-materializing convenience
API" below.

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
- Offer a value-materializing API — plain nested Scheme data, no
  `document`/`node` handles to manage — as a first-class *convenience
  layer*, not a second implementation: it must reuse the handle-based
  core's parsing, typed-scalar resolution, and multi-document
  streaming rather than duplicating any of them. This is the one part
  of the design that goes beyond matching `alibfyaml` — it exists to
  match and then exceed the two existing Chicken eggs' own core
  feature (decode to Scheme data), specifically fixing `yaml` egg's
  single-document-only limitation.

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

## Target CHICKEN version(s)

**Decided: CHICKEN 5.4.0 is the required baseline; CHICKEN 6 is a
second target, best-effort, verified empirically rather than assumed.**
Not CHICKEN 4, per explicit instruction.

CHICKEN 6.0.0 released 2026-08-10 — about a month before this section
was written — as a genuine major version with real breaking changes,
not a rebrand. Both it and 5.4.0 are already installed on this
machine (`/usr/local/sw/versions/chicken/{5.4.0,6.0.0}`), so nothing
needs to be built to target both from day one.

Breaking changes from CHICKEN's own migration notes that are relevant
here:

- `(scheme base)` is now the real R7RS base library; some bindings
  that used to live in `(chicken base)` moved there (e.g.
  `open-input-string`) and need an explicit `(import (scheme base))`
  under 6. Relevant if/when this binding's buffer-copy helpers or test
  harness reach for a string port.
- **Hex escape sequences in string literals now require a trailing
  `;`** (`\x1b;[31m`, not `\x1b[31m`) — a hard syntax break, not a
  semantic one. Adopt as a coding rule from day one: never write a
  bare `\xNN` escape without the trailing `;` (or use `\uNNNN`
  instead), so no source file in this egg ever needs a version-gated
  string literal over this.
- Redefining a record type with the same name now creates a genuinely
  new, distinct type rather than updating the old one in place — a
  live-REPL concern (iterating on `node`/`document` definitions in a
  running `csi` session), not a compiled-code one.
- FFI gained capability (structs/unions passed by value, direct
  complex-number passing) but nothing this binding needs was removed.
- Build tooling changed under the hood (hand-written `./configure`,
  `chicken-install`'s build-cache locking, a new "custom-config"
  mechanism for portable native-library configuration) — worth
  checking whether `custom-config` is a better way to express the
  `pkg-config libfyaml` link step than a hard-coded `csc-options` line
  in `slibfyaml.egg`, during the Build/packaging phase, rather than
  assuming the CHICKEN 5 idiom is still the best available one.

Confirmed live before committing to this, not assumed from the
migration notes alone:

- The list-form module names this entire plan's naming scheme depends
  on (`(module (slibfyaml thin) ...)`) compile and import identically
  under CHICKEN 6.0.0 — checked directly with `csi`.
- A `foreign-lambda` binding to a real libfyaml C function
  (`fy_document_build_from_string`) compiles, links
  (`csc foo.scm -o foo -L -lfyaml`), and runs identically under
  CHICKEN 5.4.0 and 6.0.0 against the same installed libfyaml.
- The `foreign-lambda*` C-snippet idiom this plan relies on for struct
  field access (see "Struct field access" above) also compiles and
  runs identically under both.

Not yet checked — left for the Skeleton/Packaging phases, not blocking
design now:

- Neither `yaml` nor `libyaml` (the two existing Chicken YAML eggs)
  appears in the CHICKEN 6 egg index yet (`eggs.call-cc.org/6/`,
  checked directly) — genuinely unexplored territory for a
  YAML-binding egg specifically, not just for CHICKEN 6 in general.
  Reason for care, not alarm: everything this binding actually
  mechanically depends on (list-form modules, `foreign-lambda`,
  `foreign-lambda*`) is confirmed working above: what's unconfirmed is
  only the packaging side.
- Exact `.egg`/egg-information requirements or differences for
  CHICKEN 6 (a version constraint, a separate branch/tag, anything
  `chicken-install` needs that CHICKEN 5 didn't) — not found on the
  egg index page itself; consult the CHICKEN 6 manual's egg-authoring
  section directly when writing `slibfyaml.egg` in the Skeleton phase.

Practical approach: write plain CHICKEN-5-compatible code as the
default throughout (this plan's design doesn't change), follow the
hex-escape rule unconditionally, and add
`(cond-expand (chicken-6 ...) (chicken-5 ...) (else ...))` branches —
the same mechanism the `yaml` egg already uses for its own
`chicken-4`/`chicken-5` split, just with `chicken-6`/`chicken-5` as the
feature identifiers instead — only where a real, confirmed divergence
actually shows up, not preemptively. Build and run the test suite
under both `.../5.4.0` and `.../6.0.0` from the Skeleton phase onward,
not as a late compatibility pass bolted on at the end.

## Naming

**Decided**: egg name and Scheme module family are both `slibfyaml` (no
separate short module name) — the `(import (slibfyaml nodes))`-length
tradeoff considered above is worth it for never having two names (egg
vs. module) to keep straight, and for staying unambiguous next to the
existing, oddly-named `libyaml` egg (which also binds libfyaml, despite
its name) and the real-libyaml-binding `yaml` egg.

- Egg name: `slibfyaml` (matches this repository).
- Scheme module family, mirroring `alibfyaml`'s child-package layout via
  CHICKEN 5's list-style module names (the same mechanism the existing
  `libyaml` egg uses for its own `(libfyaml yaml2ss)` /
  `(libfyaml if)` submodules):
  - `(slibfyaml thin)` — raw FFI imports (≈ `Libfyaml.Thin`)
  - `(slibfyaml)` — condition types (≈ top-level `Libfyaml`)
  - `(slibfyaml nodes)` — `node` (≈ `Libfyaml.Nodes`)
  - `(slibfyaml documents)` — `document` (≈ `Libfyaml.Documents`)
  - `(slibfyaml documents streams)` — multi-document streaming
    (≈ `Libfyaml.Documents.Streams`)
  - `(slibfyaml scheme)` — the value-materializing convenience API (see
    below), decoding a `document`/`node` into plain Scheme data
- Deliberately *not* named `libfyaml` or `libyaml` as a Scheme module,
  to avoid any confusion with the existing (differently-scoped, oddly-
  named) `libyaml` egg that also binds libfyaml.

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
more than `pragma Import` could. Reimplement them in `(slibfyaml nodes)` by
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
| `Null_Node : constant Node` | `null-node` (a distinguished `node` wrapping a null pointer) |
| `type Document is tagged limited private` (RAII, `Ada.Finalization.Limited_Controlled`) | `(define-record-type document ...)` wrapping the `Fy_Document` pointer + owned-buffer state; see Memory model below for how "RAII" is approximated |
| `Wrap`/`Raw` bridge functions (binding-internal) | Same idea: `node-wrap`/`node-raw`, `document-wrap`/`document-raw`, exported only from `(slibfyaml nodes)`/`(slibfyaml documents)` for `(slibfyaml documents streams)` to use, not part of the public API |
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
   (with-document (doc (document-parse-file "config.yaml"))
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

**Decided: yes, track owner liveness on every `node`, beyond what
`alibfyaml`'s Ada contract does.** Ada's contract is purely
documentational — "a Node is valid as long as its Document hasn't been
finalized," enforced nowhere except by the caller not misusing it — and
most of `alibfyaml`'s own confirmed bug history (`Document_Stream`
buffer lifetime, `Insert_At` use-after-free) is exactly this class of
mistake slipping past a documentation-only contract. CHICKEN can do
better for a small, fixed cost, so it should.

Design, as actually implemented in Phase 2 (see its roadmap entry
below for the one refinement this needed beyond the original sketch —
`node`'s "owner" is a shared *liveness box*, not a reference to the
`document` record itself, so `(slibfyaml nodes)` needs no dependency on
`(slibfyaml documents)` at all, avoiding a two-way inter-module
dependency CHICKEN's separately-compiled units can't express):

```scheme
;; (slibfyaml documents)
(define-record-type document
  (make-document-record handle owned-buffer liveness-box)
  document?
  (handle       document-handle)
  (owned-buffer document-owned-buffer set-document-owned-buffer!)
  (liveness-box document-liveness-box))   ; a (vector #t) or (vector #f)

;; (slibfyaml nodes) -- imports (slibfyaml thin)/(slibfyaml), NOT
;; (slibfyaml documents); owner-box is just the shared vector above,
;; not a document record reference
(define-record-type node
  (make-node handle owner-box)
  node?
  (handle handle)
  (owner-box owner-box))
```

- Every accessor in `(slibfyaml nodes)` starts by calling a shared
  `(check-node-live! n)` helper: raises `(exn slibfyaml use-after-free)`
  if `(node-owner-box n)` is truthy and its first slot is `#f`.
  `null-node` and any node with no owner box (see below) skip the
  liveness check and fall through to the existing `Is_Valid`-equivalent
  null-handle check instead — the two checks are independent, not
  layered.
- `document-destroy!` sets the box's slot to `#f` *before* calling
  `fy_document_destroy`, so a `node` accessor racing a concurrent
  destroy (not a real concern without threads, but cheap to get right)
  never observes a half-torn-down state.
- **Freshly-built, not-yet-attached nodes** (`document-create-scalar`/
  `_sequence`/`_mapping`, before `document-set-root!`/`node-append!`/
  `node-append-pair!` attaches them) still get `owner` set to the
  `document` passed to `document-create-*` — they're libfyaml-owned
  memory belonging to that document from the moment they're created,
  attached to the tree or not, so the same liveness check applies to
  them unconditionally.
- **`document-insert-at!`-consumed nodes**: per the "Insert_At-style
  consumption contracts" section below, a `node` passed to
  `document-insert-at!` has its `handle` field nulled out immediately
  regardless of outcome. This is a *different* condition from
  owner-liveness (`(exn slibfyaml consumed)`, not `use-after-free`) —
  worth two distinct condition kinds since "your document is gone" and
  "you already handed this specific node to Insert_At" are different
  mistakes with different fixes, even though both are caught by a
  guard at the top of every accessor.
- Cost: one extra field on `node` (a reference to the shared liveness
  box, not a copy of its boolean content — reading through the shared
  box means one flip in `document-destroy!` invalidates every `node`
  drawn from that document at once) and one branch per accessor call.
  Negligible next to the FFI call itself.
- This is strictly more defensive than `alibfyaml`'s Ada contract
  (which relies on `-gnata` preconditions checking `Is_Valid` — a
  null-handle check only, never a "my owner is gone" check). Revisit
  only if it turns out to be a real, measured performance concern —
  unlikely, given the accessor is already crossing the FFI boundary on
  the very next line.

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

Chicken condition types, matching the five Ada exceptions plus the two
CHICKEN-specific ones from the owner-liveness tracking decided above,
using the condition-tagging convention already used by the two
existing Chicken YAML eggs (`(exn <lib> <procedure>)`-style composite
kinds):

- `(exn slibfyaml use-after-free)` — a `node` accessor called after its
  owning `document` was destroyed. Has no Ada equivalent — see "Node
  validity after its Document is gone" above.
- `(exn slibfyaml consumed)` — a `node` accessor called on a node
  already handed to `document-insert-at!`. Also no Ada equivalent as a
  *condition* (Ada catches the equivalent mistake at compile time via
  `-gnata` preconditions on a nulled-out handle instead).
- `(exn slibfyaml parse)` — parse failure. Message formatted the same
  gcc-style way `alibfyaml`'s `Parse_Error` is
  (`file:line:column: error: message`, one line per collected
  diagnostic, via `fy_diag_errors_iterate`), a format `alibfyaml`
  arrived at deliberately (see its PLAN.md, "Parse_Error message
  reformatted to gcc diagnostic style") — no reason to make a
  different choice here.
- `(exn slibfyaml emit)` — emit failure.
- `(exn slibfyaml missing-key)` — required mapping key absent.
- `(exn slibfyaml data)` — scalar present but not resolvable as the
  requested typed-accessor's type.
- `(exn slibfyaml resolve)` — `document-resolve!` failure (e.g. a
  merge-key cycle). Same caveat `alibfyaml` documents: libfyaml doesn't
  say how much resolved before failing, so treat the document as
  unreliable afterward, not as cleanly rolled back.

Each condition carries `'message`, and `parse`/`resolve` additionally
carry structured fields (`'file`, `'line`, `'column`) alongside the
formatted message, so a caller can act on them programmatically
instead of re-parsing the message string — the existing `yaml` egg
already does this (`'line`/`'column`/`'problem`/`'context` on its parse
exception), a convention worth keeping.

### Location and Path: same two abilities as `alibfyaml`, attached automatically where Ada doesn't

`slibfyaml` gets both of `alibfyaml`'s node-diagnostic tools, for the
same reason `alibfyaml` grew both instead of just one (see its own
`Libfyaml.Nodes.Path` doc comment and the commit that added it,
"Add Libfyaml.Nodes.Path, independent of Location"): they cover
different node shapes.

- **`node-location`/`node-has-location?`** (line/column) — **scalar
  nodes only**. Backed by `fy_node_get_scalar_token`/
  `fy_token_start_mark`, which only exist for a node with a scalar
  token — a mapping or sequence node has no token to hang a position
  off of at all.
- **`node-path`/`node-by-path`** — **any node kind**, mapping and
  sequence included, via `fy_node_get_path`/`fy_node_by_path`. This is
  exactly why `alibfyaml` added `Path` after already having `Location`:
  a mapping missing a required key has no node/token for the *absent*
  key to report a `Location` for, but the mapping's own `Path` is
  always available and, combined with the missing key's name,
  unambiguously identifies where the problem is.

**Where this goes further than `alibfyaml`**: in Ada, `Required`
raising `Missing_Key` and the typed accessors raising `Data_Error`
carry only a bare message (`"missing required key ""host"""`,
`"not a valid integer: ""banana"""` — confirmed by reading
`libfyaml-nodes.adb`'s actual `raise` statements) with no `Path`/
`Location` attached; a caller who wants that context has to fetch it
themselves and combine it manually, exactly as `test/
example_missing_field.adb` demonstrates by hand. That's a reasonable
choice in Ada, where exceptions carry only a message string by
convention. **CHICKEN conditions don't have that restriction** — they
already carry structured fields for `parse`/`resolve` above, so
`slibfyaml`'s `missing-key` and `data` conditions should do the same,
automatically, since the accessor already holds the exact `node`
needed to compute it:

- `(exn slibfyaml missing-key)` carries `'path` — `(node-path map)` —
  in addition to `'message`, and the message itself folds it in
  (`"missing required key \"host\" at /server"`, echoing the same
  spirit as the gcc-style `parse` message above without literally
  reusing that format, since this isn't a file:line:column diagnostic).
- `(exn slibfyaml data)` carries `'path` (`(node-path n)`, always
  available) and, when `(node-has-location? n)` is true, `'line`/
  `'column` too — both raised automatically by the shared internal
  helper every typed accessor already funnels through to signal a
  type mismatch, so no call site has to remember to attach them.

This costs nothing extra at the point of raising (the `node` is
already in hand) and means a caller gets full "which key, where in the
tree, and if applicable what line" context from the condition object
itself, with no manual `node-path`/`node-location` call of their own
required — purely additive to what `alibfyaml` already established as
the two right tools for this job, not a different design.

Worth relaying back to `alibfyaml` as a possible enhancement (automatic
`Path`/`Location` fields on `Missing_Key`/`Data_Error`'s exception
occurrence, via `Ada.Exceptions.Exception_Information` or a dedicated
accessor) rather than requiring `example_missing_field.adb`'s
manual-combination pattern at every call site — flagging this as a
suggestion, not doing it, since changing what an already-shipped
exception carries is a bigger behavioral change there than adding a
field to a condition type that doesn't exist yet here.

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
  with the typed family) — raise `(exn slibfyaml data)` on a mismatch.
- `node-integer?`, `node-float?`, `node-boolean?` — non-raising shape
  predicates, same purpose as Ada's (deciding a scalar's shape before
  committing to a conversion).
- Mapping-collapsed forms: `(node-integer-value map key)` /
  `(node-integer-value map key default)` and the same pattern for
  `float`/`boolean`/`string`, using CHICKEN's `#!optional` rather than
  Ada's required-vs-optional overload pair. Required form raises
  `(exn slibfyaml missing-key)` if absent, `(exn slibfyaml data)` if present
  but malformed; supplying `default` only substitutes for absence, per
  `alibfyaml`'s explicit design rule that a default must never mask a
  malformed value.

## API surface sketch

Organized the same way `alibfyaml`'s `Libfyaml.Nodes`/`Libfyaml.Documents`
are; exact signatures to firm up during implementation, not frozen here.

```scheme
;; (slibfyaml documents)
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

;; (slibfyaml nodes)
(node-valid? n) (null-node)
(node-kind n)                            ; 'scalar | 'sequence | 'mapping
(node-scalar? n) (node-sequence? n) (node-mapping? n)
(node-null-value? n)
(node-scalar-value n)
(node-has-location? n) (node-location n) ; -> (values line column)
(node-integer? n) (node-float? n) (node-boolean? n)
(node-integer-value n) (node-float-value n) (node-boolean-value n)
(node-length n) (node-item n index)      ; 1-based
(node-append! seq item)
(node-iterate-items seq visit-proc)      ; visit-proc: (element) -> _
(node-value map key) (node-has-key? map key) (node-required map key)
(node-append-pair! map key value)
(node-iterate-pairs map visit-proc)      ; visit-proc: (key value) -> _
(node-integer-value map key) (node-integer-value map key default)
;; ... float/boolean/string, same pattern
(node-by-path n path) (node-path n)
(node-alias? n) (node-tag n)

;; (slibfyaml documents streams)
(document-stream-open-string string)
(document-stream-open-file path)
(document-stream-has-next? stream)
(document-stream-next! stream)           ; -> document

;; (slibfyaml scheme)
(node->scheme n)                         ; -> plain Scheme data, any node
(load-string string #!optional (resolve-anchors? #t))  ; -> list of values
(load-file path #!optional (resolve-anchors? #t))      ; -> list of values
```

**Decided: two names, `node-iterate-items` (sequence) and
`node-iterate-pairs` (mapping)**, not one `node-iterate` dispatching on
`node-kind`. Scheme has no static arity-based overload resolution the
way Ada's two `Iterate` procedures get resolved by parameter profile,
and the two kinds' natural visitor shapes genuinely differ: a sequence
visitor takes one argument (`element`), a mapping visitor takes two
(`key value`). A single dispatching `node-iterate` would have to either
inspect the visitor procedure's arity at runtime (fragile — CHICKEN can
check `procedure-arity`, but it's an odd thing to lean on for dispatch)
or force both kinds through one uniform shape, e.g. always calling the
visitor as `(index-or-key value)` — which changes a sequence visitor's
signature from "just the element" to "index and element" just to keep
a single name, distorting the more common case to accommodate the
less common one. Two names avoid distorting either kind's visitor
shape and cost nothing but one extra exported identifier.

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
usable input state. After a `(exn slibfyaml parse)` from
`document-stream-next!`, treat the stream as exhausted:
`document-stream-has-next?` should report a clean `#f` rather than
raising again, even though the underlying input may textually contain
more documents after the malformed one. (Ada's own binding got this
wrong once — raising `Libfyaml.Parse_Error` a second time, quoting the
first error's now-stale message — before fixing it; no reason to
re-introduce that bug here by not planning for it up front.)

## Value-materializing convenience API: `(slibfyaml scheme)`

The requirement this section plans for: an entry point that returns
plain Scheme data the way `yaml` egg's `yaml-load` and `libyaml` egg's
`yaml->ss` do, but that can read every document in a multi-document
stream, not just one — fixing `yaml` egg's actual limitation
(`yaml-load` collapses its parse seed to `(car seed)` on every
`document-end`, so each document's result clobbers the last and it can
only ever return the *last* document of the stream, not the first —
confirmed live, not just read off the source) without inheriting
`libyaml` egg's awkward fix for the same problem (its `yaml->ss`
returns a *callable* you invoke with a document index or `-1` for "all
of them," rather than just handing back the data).

### Design: a decoder over the handle-based core, not a separate parser

This is the reason the handle/tree core comes first in the roadmap
rather than being built in parallel: `(slibfyaml scheme)` is a pure
consumer of it, adding no new C calls of its own.

- **`(node->scheme n)`** — the core primitive. Recursively decodes any
  `node` (not just a document root — a genuine advantage of building
  this on the handle-based core, since neither existing egg's decoder
  can be pointed at a sub-tree) into plain Scheme data:
  - mapping → alist: `(list (cons key-value value-value) ...)`, keys
    and values themselves decoded recursively via `node->scheme`
  - sequence → list: `(list item-value ...)`
  - scalar → whichever of `(node-integer-value n)`,
    `(node-float-value n)`, `(node-boolean-value n)`, `'()` (null), or
    `(node-string-value n)` actually matches, using the *same* typed
    predicates the handle-based core already implements against YAML
    1.2 core schema (plus its two documented extensions) — this is
    strictly more rigorous than `yaml` egg's ad hoc regex cascade or
    `libyaml` egg's separate regex-based `scalar->ss`, and costs
    nothing extra to get since the typed accessors already exist for
    the handle-based API.
  - Because the shape (mapping vs. sequence) is always known from
    libfyaml's own `node-kind` while decoding, **this direction has
    none of `yaml` egg's mapping/sequence ambiguity** — that ambiguity
    only bites `yaml` egg's *emitter*, which has to guess a Scheme
    value's intended YAML shape from its structure alone (is this list
    of pairs a mapping or a sequence of dotted pairs?). A pure decoder
    never has to guess.
  - Anchors/aliases need no special handling in the walker at all: by
    the time `node->scheme` sees a node, `document-resolve!` (default
    `#t` on parse, per the handle-based core's `resolve-anchors?`) has
    already replaced every alias with its resolved content — unlike
    `yaml` egg, which has to hand-roll an anchor hash-table during
    event parsing to get the same result.
- **`(load-string string #!optional (resolve-anchors? #t))`** and
  **`(load-file path #!optional (resolve-anchors? #t))`** — the actual
  multi-document entry points. Internally: open a
  `(slibfyaml documents streams)` `document-stream` over the input,
  pull every document with `document-stream-has-next?`/
  `document-stream-next!`, `node->scheme` each one's root, destroy each
  `document` once decoded (nothing from the tree needs to survive past
  decoding — the whole point of this API is that the caller never
  touches a `document`/`node` at all), and **always return a list of
  decoded documents**, even for single-document input (a length-1
  list) — no thunk, no index argument, no `-1` sentinel. This is a
  deliberate departure from `libyaml` egg's `yaml->ss` shape: returning
  the callable-you-invoke-with-an-index design was already flagged (in
  this project's earlier sibling-comparison note) as an awkward extra
  indirection for the common case; a plain list has none of that, and
  `(car (load-string ...))` is exactly as short as `libyaml` egg's
  `((yaml->ss ...))` for the single-document case anyway.
- No `load-string-first`/`load-file-first` convenience wrapper planned
  up front — `(car (load-string ...))` is short enough that a separate
  name would just be one more thing to keep in sync with `load-string`
  itself; add one later only if real call sites show it's actually
  wanted.

### Explicitly not planned (for now): the inverse direction

An `alist`/`list` decode has no ambiguity (see above), but a
**Scheme-data-to-YAML *encoder*** built the same way `yaml` egg's
`yaml-dump`/`walk-objects` is — guessing mapping-vs-sequence from a
plain Scheme value's shape — would inherit exactly the ambiguity `yaml`
egg has (a sequence whose first element happens to be a non-list pair
misdumps as a mapping), since libfyaml's own `document-create-*`/
`node-append!`/`node-append-pair!` calls need to be told which kind of
node to build and a plain nested list/alist alone doesn't always say.
Two options if this is wanted later, deliberately deferred rather than
decided now:

1. Accept the same ambiguity `yaml` egg lives with (alist-of-pairs vs.
   list, same heuristic).
2. Adopt `libyaml` egg's disambiguating convention instead — mapping as
   a one-element list wrapping an alist, sequence as a vector — which
   resolves the ambiguity outright at the cost of not looking like
   `yaml` egg's shape on the way in.

Since the immediate ask is decoding (matching `yaml` egg's read side,
fixing its multi-document gap), building an encoder is out of scope
for the phase this plan currently covers. The handle-based core's own
`document-create-*`/`node-append!`/`node-append-pair!` (Phase 4)
already cover "build a document programmatically" for anyone who wants
to construct one explicitly, node by node, with no ambiguity — that
need not wait on a Scheme-data encoder existing at all.

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
  `test-location`, `test-path` (including a `missing-key`/`data`
  condition's automatic `'path`/`'line`/`'column` fields — the
  `slibfyaml` case mirroring what `alibfyaml`'s `test/
  example_missing_field.adb` demonstrates by hand).
- `test-scheme` — `(slibfyaml scheme)` coverage: single- and
  multi-document `load-string`/`load-file` (asserting a list is always
  returned, length matching document count), `node->scheme` on a
  sub-tree (not just a document root), typed-scalar decoding for every
  case `test-scalars` already covers, and a document containing
  anchors/aliases decoded with `resolve-anchors?` both `#t` and `#f`.
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
  component(s) for `slibfyaml`/`slibfyaml.thin`/`slibfyaml.nodes`/
  `slibfyaml.documents`/`slibfyaml.documents.streams`/`slibfyaml.scheme`,
  linking via `pkg-config libfyaml` (mirroring how other C-binding eggs in the
  CHICKEN ecosystem express link flags — confirm exact `.egg`
  csc-options syntax against a recent binding egg before writing this,
  rather than guessing).
- No C headers to compile (pure FFI import layer, same as
  `alibfyaml`) — only the linker needs to find `libfyaml.so`.

## Open questions

- License: `alibfyaml` currently has none chosen either; the two
  existing Chicken YAML eggs are BSD-style (`yaml`) and MIT
  (`libyaml`). Pick one before the first public release, doesn't block
  design/implementation.
- CHICKEN 4 support: not planned, not requested. See "Target CHICKEN
  version(s)" above for the CHICKEN 5/6 decision instead.
- `!scheme/symbol` tag support: `yaml` egg special-cases a scalar
  tagged `!scheme/symbol`, decoding its text as a Scheme symbol
  (`(string->symbol ...)`, after stripping a leading `:`) rather than
  a string — see the "Also: plain Scheme data" section's `yaml-load`
  comparison. `(slibfyaml scheme)`'s `node->scheme` currently does no
  tag-based dispatch at all (only shape-based: mapping/sequence/scalar
  from `node-kind`, then core-schema type resolution for scalars) —
  a tagged node's own tag (`node-tag`, since Phase 5) is available but
  unused by the decoder. Consider before adding it:
  - Whether symbol round-tripping is actually wanted here, or is
    `yaml` egg's own Scheme-specific workaround for not otherwise
    being able to dump/load a symbol distinctly from a string —
    relevant only if `(slibfyaml scheme)` ever grows the encoder
    direction (see "Explicitly not planned (for now): the inverse
    direction" below); a decode-only reader has less reason to invent
    a write-side convention nothing here yet produces.
  - Whether it should be on by default or opt-in: an existing document
    from another tool that happens to use `!scheme/symbol` for its own
    unrelated purpose would silently decode differently than intended
    if this egg treated the tag as a universal convention rather than
    one specific to round-tripping *this* egg's own output.
  - Scope: `yaml` egg only special-cases this one tag on scalars;
    generalizing to arbitrary custom tags on mappings/sequences too
    is a much bigger design question (schema selection, effectively)
    that nothing here currently needs.
  Not blocking anything currently planned — `node->scheme`/
  `load-string`/`load-file` work fully without it; revisit if a real
  call site wants Scheme symbols preserved through a YAML round-trip.

## Phased roadmap

1. **`[done]` Skeleton**: `.egg` file, `(slibfyaml thin)` with the full
   confirmed C function list bound (no logic yet), builds and links
   against system `pkg-config libfyaml` under both
   `/usr/local/sw/versions/chicken/5.4.0` and `.../6.0.0`.

   Confirmed live, resolving both "not yet checked" CHICKEN 6 items
   from "Target CHICKEN version(s)" above: `slibfyaml.egg`'s
   `(extension slibfyaml.thin (source "slibfyaml-thin.scm")
   (link-options "-L" "-lfyaml"))` builds, installs, and imports
   identically under both CHICKEN versions via real `chicken-install`
   runs into isolated scratch prefixes (`CHICKEN_INSTALL_PREFIX=...
   chicken-install`, then `csi` against
   `CHICKEN_REPOSITORY_PATH=$PREFIX/lib/chicken/<N>` — `<N>` is `11`
   for 5.4.0, `12` for 6.0.0 on this machine) — no CHICKEN-6-specific
   `.egg` field or divergence needed. `tests/test-thin.scm` (parse
   `"hello: world"`, walk root → mapping → scalar, read the value back
   byte-for-byte via `move-memory!`, destroy) passes identically under
   both versions and is confirmed leak/error-free under valgrind.

   Two mechanics needed to get a list-form-named module
   (`(module (slibfyaml thin) ...)`) to build and link as a separate
   unit at all, found by trial rather than documented anywhere obvious
   (see AGENTS.md's Build section for the exact commands): `-unit
   slibfyaml-thin` when compiling the module (otherwise it emits its
   own `main`/`C_toplevel` and collides with whatever links against
   it), and `-J`/`-emit-all-import-libraries` (otherwise no
   `.import.scm` is emitted at all and nothing can `(import (slibfyaml
   thin))` it). `chicken-install` itself gets both right automatically
   from the `.egg` file's `extension` declaration — only the manual
   `csc`-only inner-loop workflow needs them spelled out.

   One deliberate, load-bearing typing decision confirmed necessary
   while writing this module, beyond what "no logic yet" might suggest:
   `fy_node_get_scalar`/`fy_node_get_tag`'s text result and
   `fy_node_get_path`/`fy_emit_document_to_string`'s heap-allocated
   result are all typed `c-pointer` here, never `c-string` — CHICKEN's
   `c-string` return marshaling scans for a NUL terminator (wrong for a
   zero-copy span that may have more non-NUL bytes after its intended
   end) and copies into a fresh GC'd Scheme string immediately (losing
   the original pointer a caller-owned result would need to pass to
   `c-free`). See `slibfyaml-thin.scm`'s own header comment and
   AGENTS.md's Conventions section.
2. **`[done]` Read-only parse + navigate**: `document-parse-string`/
   `-parse-file` (with the copy-always buffer strategy from day one,
   not retrofitted), `document-root`, `node-kind`/predicates,
   `node-scalar-value`, `node-length`/`node-item`, `node-value`/
   `node-has-key?`, `node-iterate-items`/`node-iterate-pairs`, `node-by-path`/
   `node-path`. `test-quickstart`/`test-navigate` ported (using
   `alibfyaml`'s own `config.yaml`/`navigate.yaml` fixtures directly),
   passing and confirmed leak/error-free under valgrind under both
   CHICKEN 5.4.0 and 6.0.0.

   Also delivered, ahead of where the roadmap originally placed them,
   because `document-parse-string` can't raise a real parse failure
   without them: the `parse` and `use-after-free` condition kinds from
   Error handling (not the whole set -- `missing-key`/`data`/`resolve`/
   `emit`/`consumed` still wait for the phases that actually introduce
   the operations that raise them, same "bind exactly what's needed"
   discipline already applied to the C function surface). Both
   exercised directly in `test-quickstart.scm` (a deliberately
   malformed parse, and a node accessor called after its document was
   destroyed), not just unit-tested in isolation.

   One implementation-time refinement to the Memory model's `node`
   sketch: `node`'s `owner` field turned out to need to be a shared
   *liveness box* (a one-element mutable vector, flipped by
   `document-destroy!`), not a reference to the actual `document`
   record as originally sketched -- `(slibfyaml nodes)` needs no
   dependency on `(slibfyaml documents)` at all this way, which matters
   because `(slibfyaml documents)` already has to depend on
   `(slibfyaml nodes)` (to wrap `fy_document_root`'s result), and
   CHICKEN modules compiled as separate units can't depend on each
   other in both directions. See `slibfyaml-nodes.scm`'s own header
   comment for the full reasoning.

   Also found live, not assumed: `chicken-install` needs no intra-egg
   `component-dependencies`-style declaration between `slibfyaml.egg`'s
   components (tried it, then removed it after confirming an identical
   working result without it) -- unlike the manual `csc -uses` inner
   loop, which does need each module's real dependencies declared *at
   that module's own compile step*, not just the final program's. See
   AGENTS.md's Build section for the full writeup, including the
   separate `CHICKEN_REPOSITORY_PATH`-replaces-rather-than-extends
   gotcha found while verifying this against a real installed egg.
3. **`[done]` Typed scalars**: `node-null-value?`, `node-integer?`/
   `node-float?`/`node-boolean?`, `node-integer-value`/`node-float-value`/
   `node-boolean-value`/`node-string-value` in all three arities (bare
   node; required `(map key)`; optional `(map key default)`), and
   `node-required`. Core schema (null/bool/int/float) plus both
   documented extensions (`0b` binary, `_` digit separators), grammar
   logic ported directly from `libfyaml-nodes.adb`'s private
   validation/parsing helpers, not reimplemented from the schema spec
   from scratch. `test-scalars` ported from `alibfyaml`'s own
   `test_scalars.adb`, using its `scalars.yaml` fixture directly
   (51 checks), passing and confirmed leak/error-free under valgrind.

   Two deliberate, documented divergences from the Ada original, both
   from the per-width-overload collapse already anticipated in this
   file's own "Typed scalar accessors" section: `big_int`/`huge_int`
   (chosen in `scalars.yaml` to overflow Ada's 32-/64-bit `Integer`
   forms) succeed here as ordinary bignums instead of raising
   `Data_Error`; `float_overflow` (chosen to overflow only Ada's 32-bit
   `Float`) succeeds here as a plain double instead of needing the
   `Long_Float`-only accessor Ada does -- only `huge_float`, which
   overflows even a 64-bit double to `+inf.0`/`-inf.0`, still exercises
   the "float out of range" `data` condition.

   New condition kinds `(exn slibfyaml missing-key)` and
   `(exn slibfyaml data)`, per this file's own "Location and Path"
   section's decision -- both carry `'path` (`node-path`) automatically,
   attached by the raiser rather than left to the caller;
   `missing-key`'s message folds `'path` into the text too
   (`"missing required key \"x\" at /y"`), `data`'s does not (matching
   `alibfyaml`'s own bare `Data_Error` message text, with `'path` only
   as a structured field on top). `'line`/`'column` on `data` are
   deferred to Phase 8, which is where `node-location`/
   `node-has-location?` (the only source for them) are introduced --
   noted at the two `raise-data-error` call sites in
   `slibfyaml-nodes.scm` so this isn't forgotten.

   Implementation-time findings: CHICKEN's `#!optional` has no
   supplied-p the way some other Lisps do, so each of the three-arity
   accessors dispatches on whether trailing args were actually passed
   via a private `eq?`-compared sentinel object (`unsupplied`), not on
   `#f` (a legitimate default value) or arg count directly. `filter`/
   `string->list` (the obvious way to strip `_` separators) turned out
   to need `srfi-1`, not available under this module's existing plain
   `scheme` + `(chicken base)` imports -- rewritten as an explicit
   index-copying loop over `make-string`/`string-set!` rather than
   adding a new egg dependency for one four-line helper. Confirmed live
   (not assumed) that CHICKEN's `string->number` accepts a leading sign
   combined with an explicit radix argument directly (`(string->number
   "-1A" 16)` => `-26`), which is what lets `parse-integer-text` hand
   the sign-plus-digits straight to `string->number` without
   `alibfyaml`'s own `Integer_Literal_Text` based-literal-rewrite step
   (an Ada-syntax-specific need that doesn't exist here); also confirmed
   that a double-precision literal overflow (`(string->number "1e400")`)
   returns `+inf.0` rather than raising, which is what
   `float-value-of-node` checks for explicitly.
4. **`[done]` Build + emit + mutate**: `document-create-scalar`/
   `-sequence`/`-mapping`, `document-set-root!`, `node-append!`/
   `node-append-pair!`, `document->yaml-string`/`-write-to-file!`
   (`emit-default`/`emit-sort-keys`/`emit-mode-block`/`emit-mode-flow`/
   `emit-mode-flow-oneline`/`emit-mode-json`, the same subset `alibfyaml`
   binds out of libfyaml's larger emitter-flag set), and
   `document-insert-at!` with its unconditional-consumption discipline.
   `test-mutate` ports `alibfyaml`'s own `test_mutate.adb`'s three
   `Insert_At` scenarios directly (replacing a scalar, merging a mapping,
   an invalid path), extended with coverage for the rest of this phase's
   surface that `alibfyaml` doesn't bundle into one test file the same
   way — 21 checks, confirmed leak/error-free under valgrind.

   Confirmed against the Ada source before porting, not assumed: unlike
   `document-insert-at!`, `node-append!`/`node-append-pair!`/
   `document-set-root!` do **not** consume their node arguments —
   `fy_node_sequence_append`/`fy_node_mapping_append`/
   `fy_document_set_root`'s own headers document no unref, confirmed
   directly against `libfyaml-nodes.adb`'s `Append`/`Append_Pair` and
   `libfyaml-documents.adb`'s `Set_Root`, each of which leaves its node
   argument valid and reusable afterward. Also confirmed: `Set_Root`/
   `Insert_At`/`Append`/`Append_Pair` all raise a generic Ada
   `Program_Error` on a nonzero libfyaml status (not one of `alibfyaml`'s
   five domain exceptions) — mirrored here as a plain `(error ...)`, the
   same choice already made for `node-kind`'s own "should never happen"
   case, rather than inventing a new condition kind Ada itself doesn't
   have an equivalent domain exception for.

   The consumption discipline itself is `document-insert-at!` porting a
   bug `alibfyaml` already hit and fixed, confirmed live with valgrind
   there: `fy_document_insert_at` unconditionally unrefs its node
   argument, on success as much as on failure, freeing a freshly-built
   node with no other reference either way — an earlier `alibfyaml`
   version only nulled its own `N` out on failure, so a *successful*
   merge left the caller holding a node pointing at memory libfyaml had
   already freed (masked without valgrind, since the freed bytes
   happened to still look plausible). `slibfyaml` goes one step further
   than Ada's null-out-and-rely-on-a-`-gnata`-precondition approach: the
   `node` record gained a third field, a mutable `consumed?` flag (not
   just nulling `handle`, though that happens too, for parity with Ada's
   own `N := Null_Node`), checked by `check-node-live!` -- the single
   guard every accessor already called first — so a consumed node raises
   the new `(exn slibfyaml consumed)` condition on any further use,
   rather than either touching freed memory or merely reading back as
   `node-valid?` = `#f` with no explanation why. One shared edit point
   (`check-node-live!`) was enough; no accessor body needed touching.
5. **`[done]` Anchors/resolve**: `document-resolve!`, `node-alias?`,
   `node-tag` (`resolve-anchors?` on parse already existed from Phase 2).
   `test-anchors` ports all 5 of `alibfyaml`'s own `test_anchors.adb`
   scenarios directly, using its `anchors.yaml`/`anchors_cycle.yaml`
   fixtures for comparability -- default-resolved parse, an explicit
   `resolve-anchors? #f` parse followed by an explicit
   `document-resolve!`, tag inspection, and `(exn slibfyaml resolve)`
   on a genuine merge-key reference loop.

   Nothing new needed at the thin FFI layer this phase — `document-
   resolve!`/`node-tag` are thin wrappers around `fy_document_resolve`/
   `fy_node_get_tag`, both already bound back in Phase 1's
   full-non-variadic-surface pass. `node-alias?` has no C symbol to bind
   at all: `fy_node_is_alias` is a `static inline` header wrapper
   (`fy_node_get_type(fyn) == FYNT_SCALAR && fy_node_get_style(fyn) ==
   FYNS_ALIAS`), not an exported/linkable symbol, so — confirmed against
   `libfyaml-nodes.adb`'s own `Is_Alias`, which reimplements it the same
   way — `node-alias?` is reimplemented directly in Scheme, the same
   division of labor already used for `node-scalar?`/`node-sequence?`/
   `node-mapping?`.

   Confirmed live (not just asserted from the Ada port): libfyaml
   detects a merge-key reference loop itself
   (`fy_document_resolve` -> `fy_check_ref_loop`) and returns a clean
   failure status rather than hanging — this also retroactively confirms
   this session's own OOM-postmortem reasoning (which had already ruled
   out anchor cycles for the specific incident investigated, since
   neither fixture in use at the time had any) generalizes: even a
   fixture built specifically to be a reference cycle is safe to parse
   and resolve. One caveat carried forward unchanged from `alibfyaml`'s
   own finding, and reproduced here bit-for-bit against the identical
   installed package (`libfyaml-0.8-9.fc44`): resolving that exact cycle
   fixture leaks a small, fixed amount of memory (confirmed under
   valgrind: 64 bytes definitely lost + 440 bytes indirectly lost)
   entirely inside libfyaml's own diagnostic path
   (`fy_check_ref_loop` -> `fy_document_diag_report` ->
   `fy_document_diag_vreport`) — not a defect in this binding, nothing
   to fix on this side, same conclusion `alibfyaml` already reached
   against the same libfyaml build.
6. **`[done]` Multi-document streaming**: `(slibfyaml documents
   streams)` — `document-stream-open-string`/`-open-file`,
   `document-stream-has-next?`/`-next!`, `document-stream-destroy!`,
   `with-document-stream`. `test-streams` ports most of `alibfyaml`'s
   own `test_streams.adb` (file-stream/string-stream/empty/single-
   document/mid-stream-parse-error scenarios, 19 checks);
   `test-buffer-lifetime` gets its own dedicated file (per this
   section's own earlier call for one) covering the one scenario that
   took `alibfyaml` a real, valgrind-caught use-after-free to find: a
   document drawn from a string-backed stream, still correctly
   readable after that stream is destroyed. Both confirmed leak/
   error-free under valgrind, including that exact scenario, on the
   first implementation attempt (the fix was ported in from reading
   `alibfyaml`'s history first, not rediscovered the hard way here).

   The refcounted buffer-ref design was implemented exactly as
   sketched above, with one refinement found live: `alibfyaml`'s own
   `Document.Owned_Buffer` is UNIFORMLY a refcounted `Buffer_Ref` —
   even plain `Parse_String`'s (count starts at 1, released as its sole
   holder's own `Document` is finalized) — not a bare pointer for the
   non-shared case and a refcounted one only for streams. Matched here:
   `document-parse-string`'s own buffer is now wrapped the same
   `buffer-ref` way `document-stream-open-string`'s is (Phase 2's
   original bare-pointer `document-destroy!` was refactored to release
   through this one path uniformly), and a new `document-wrap`
   helper factors out the make-record-plus-set-finalizer! pattern both
   `document-parse-string`/`-file` and `document-stream-next!` need,
   rather than duplicating it a third time.

   A second, independent bug-before-it-happens finding (not present in
   the Ada port — found by reading the real installed
   `/usr/include/libfyaml.h` directly rather than trusting the header
   comment inherited via the Ada translation): `fy_parser_set_input_file`
   retains its `file` pointer *past* the call ("while the parser is in
   use the file[name] will must be available", confirmed against the
   header — the file is evidently opened lazily, per
   `fy_parse_load_document` call). `slibfyaml-thin.scm`'s own Phase-1
   declaration for this had typed that parameter `c-string` — CHICKEN's
   transient marshaling, valid only for the duration of one call — a
   latent bug that simply never manifested because nothing called this
   function until this phase. Fixed by retyping it `c-pointer` and
   having `document-stream-open-file` manage a persistent,
   NUL-terminated `malloc`'d copy of the path itself (a new `poke-nul!`
   thin helper supplies the one primitive — writing a single byte at an
   offset — `c-malloc`/`move-memory!` didn't already provide for turning
   a copied buffer into a NUL-terminated one), the same buffer-lifetime
   discipline `document-parse-string`'s own text buffer already used.
   `fy_document_build_from_file`'s own `c-string` path parameter needed
   no such change — confirmed (by both `alibfyaml` and this project
   already) to be genuinely one-shot/immediate, unlike the streaming
   parser's lazy-open behavior.

   Streaming documents come back unresolved by default (no
   `resolve-anchors?` parameter on `document-stream-open-string`/
   `-open-file`, matching `alibfyaml`'s own `Open_String`/`Open_File`
   exactly, which pass no `FYPCF_RESOLVE_DOCUMENT` flag either) — call
   `document-resolve!` on a document drawn from a stream if anchor/
   alias resolution is wanted.
7. **`[done]` Value-materializing API**: `(slibfyaml scheme)` —
   `node->scheme`, `load-string`/`load-file`, built on phases 2/3/6
   above as a pure consumer (no new C calls, no new condition kinds).
   Unlike every other phase, no `alibfyaml` source exists to port —
   Ada is statically typed and has no equivalent "decode to one generic
   native value" operation — so this design is `slibfyaml`-specific,
   motivated by parity with the existing `yaml`/`libyaml` Chicken eggs
   instead (see this file's own "Value-materializing convenience API"
   section). `node->scheme`'s scalar dispatch checks integer before
   float deliberately (any valid integer text is also valid float
   grammar, confirmed back in Phase 3 -- e.g. `"42"` is both
   `node-integer?` and `node-float?` -- so checking float first would
   silently widen every integer into a flonum); boolean/null never
   overlap with int/float/each other so their relative order doesn't
   matter. `test-scheme` covers scalar/mapping/sequence decoding
   (including a malformed value degrading gracefully to its literal
   string rather than raising, unlike the low-level typed accessors),
   `node->scheme` on a sub-tree, single- and multi-document
   `load-string`/`load-file`, and `resolve-anchors?` `#t`/`#f`.
   Confirmed leak/error-free under valgrind.

   **A genuinely new bug found while writing this phase's test, not one
   `alibfyaml`'s own test suite already surfaced**: `node->scheme` on an
   *unresolved* alias node drawn from `load-string`/`load-file` (i.e.
   via the streaming parser, `document-stream-*`) intermittently
   decoded as `'()` (null) instead of falling through to its literal
   anchor-name text — reproduced consistently across native runs, but
   only after enough prior heap activity (single-file scratch
   reproductions in isolation did not trigger it). Root-caused with
   valgrind's `--track-origins=yes` rather than guessed: the
   uninitialized value traces to a heap allocation entirely inside
   libfyaml itself — `fy_token_alloc_rl` (`fy-token.h`) via
   `fy_token_queue_simple_internal`/`fy_fetch_value`/`fy_fetch_tokens`/
   `fy_scan_peek`/`fy_scan_remove_peek`/`fy_parse_internal`
   (`fy-parse.c`) via `fy_document_builder_load_document`
   (`fy-docbuilder.c`) via `fy_parse_load_document` (`fy-doc.c`) — read
   when `node-null-value?` calls `fy_node_is_null` on that node.
   Confirmed narrowly scoped, not assumed: `document-parse-string`/
   `-file`'s one-shot `fy_document_build_from_string`/`_file` path does
   not allocate through this same code and never reproduces it in
   isolation; only the streaming parser (`fy_parse_load_document`) can.
   Also explains why a first valgrind run of the reproducing case
   showed the uninitialized-value *warning* but still printed the
   *correct* answer — valgrind's own memory layout happened to leave
   the field zeroed, masking the very bug it was flagging; native runs
   hit nonzero garbage there consistently instead.

   Fixed in `node-null-value?` (not in libfyaml, which is out of this
   binding's control) by short-circuiting to `#f` for any
   `node-alias?` node, skipping `fy_node_is_null` — and the separate
   null-text-spelling check — entirely for aliases. This is justified
   independently of the libfyaml bug, too: an unresolved alias's own
   text is a reference name, not real content (an anchor literally
   named `"null"` would otherwise wrongly read as null-valued before
   resolution, a latent issue `alibfyaml`'s own identically-structured
   `Is_Null_Value` would share if it were ever exercised the same way),
   so neither check is a meaningful question to ask pre-resolution —
   `node->scheme`'s own contract already assumes resolution has
   happened for accurate typed decoding, and `resolve-anchors? #f` is
   an explicit escape hatch for inspecting the raw tree, where "not
   conclusively null" is the honest, safe answer for an alias either
   way.
8. **`[done]` Diagnostics polish**: gcc-style `Parse_Error` formatting
   was already delivered back in Phase 2 (`collected-errors` in
   `slibfyaml-documents.scm` already builds one
   `"file:line:column: error: msg"` line per collected libfyaml error)
   — confirmed still true and covered by the new `test-parse-errors`
   below, not redone. The phase's actual new work: `node-location`/
   `node-has-location?` in `slibfyaml-nodes.scm`, ported directly from
   `Libfyaml.Nodes.Location`/`Has_Location` (`fy_node_get_scalar_token`
   + `fy_token_start_mark`, both already declared in the thin layer
   since Phase 1) — peeking `struct fy_mark`'s `line`/`column` fields
   the same small-C-snippet `foreign-lambda*` way
   `slibfyaml-documents.scm`'s own `diag-error-*` accessors already
   peek `struct fy_diag_error`, converting libfyaml's own 0-indexed
   mark to 1-indexed to match this egg's existing gcc-style
   parse-error formatting (and ordinary editor/human expectations),
   same as `alibfyaml`'s own conversion. `node-location` returns two
   values (`line`, `column`) rather than a record, the more idiomatic
   Scheme shape for what Ada represents as a two-field `Node_Location`
   record.

   `(exn slibfyaml data)`'s `'line`/`'column` fields, deferred from
   Phase 3 specifically pending `node-location`'s existence (see that
   phase's own writeup and the two call-site comments this closes
   out), are wired up now: `raise-data-error` in `slibfyaml.scm`
   changed from a 2-arg (`message path`) to a 4-arg (`message path line
   column`) signature — plain required args, not `#!optional`, so
   `(slibfyaml)` doesn't need to start importing `(chicken base)` just
   for this — and all 6 call sites in `slibfyaml-nodes.scm` updated:
   the 3 scalar-grammar-mismatch sites (`integer-value-of-node`/
   `float-value-of-node`/`boolean-value-of-node`) pass a real
   `(scalar-location n)` result (a small private helper wrapping
   `node-has-location?`/`node-location`, since `n` is already confirmed
   scalar by every caller there); the 2 "key ... is not a scalar
   value" sites pass `#f #f`, since the offending value there is
   non-scalar and has no scalar token to report a position for at
   all — the same gap `node-has-location?`'s own doc comment already
   covers, not a new limitation introduced here.

   `test-location` (15 checks) ports `alibfyaml`'s own
   `test_location.adb` line for line, using a new
   `tests/location.yaml` fixture copied from `alibfyaml`'s own:
   `node-has-location?`/`node-location` on three ordinary keys
   (including an empty/omitted scalar, which still carries a real,
   zero-width location, not a missing one), on `anchors.yaml`'s
   existing unresolved alias node (confirmed live, same as `alibfyaml`
   found: the location is of the alias's own anchor-name text, column
   8, not the `*` sigil at column 7), and on a freshly-built
   (`document-create-scalar`) node — `node-has-location?` is `#t` there
   too (a synthetic all-zero mark, not a `NULL` one) but `node-location`
   is the fixed `(1, 1)`, not a real source position; pinned down here
   the same reason `alibfyaml`'s own test pins it down, so a future
   change to the underlying libfyaml call can't silently start
   returning something else unnoticed. 15/15 checks pass, confirmed
   leak/error-free under valgrind.

   `test-parse-errors` ports `alibfyaml`'s own `test_parse_errors.adb`
   — there, a regression test for a `Parse_Common` double-free hit on
   *every* single parse failure (see that file's own header comment);
   this binding's `parse-common` already destroys its `fy_diag` exactly
   once on every path (see Phase 2's own writeup, "matching alibfyaml's
   own Parse_Common... rather than risking the double-destroy bug
   alibfyaml hit once"), ported in with the fix already known rather
   than rediscovered, so this specific bug class was never actually
   present here — confirmed clean under valgrind on the first attempt,
   not after finding it the hard way. The test still earns its place:
   it's the only place covering `document-parse-file` (not just
   `-parse-string`) on malformed input, the message's non-emptiness, a
   second independent failure right after the first (confirming no
   cross-call `fy_diag` state survives to corrupt), and successful
   parsing after both — using a new `tests/malformed.yaml` fixture
   copied from `alibfyaml`'s own. Goes one step further than the Ada
   original where this binding's condition already can: `alibfyaml`'s
   `Parse_Error` carries only a message string (an Ada exception has no
   structured fields), so its test greps the message text for the file
   field; here the `'parse` condition kind's own `'file` property
   (already existing since Phase 2) is checked directly instead. 7/7
   checks pass, confirmed leak/error-free under valgrind.

   Not built, confirmed out of scope rather than merely deferred, per
   `alibfyaml`'s own `test_location.adb` header comment (re-verified
   against the same libfyaml header linked here): `FYPCF_CREATE_MARKERS`
   (no such flag exists — ordinary parsing already produces marks, no
   opt-in needed) and `fy_node_get_start_token` (the real name is
   `fy_node_get_scalar_token`, scalar-only — there is no generic "start
   token of any node" for a sequence/mapping node). A node's tag
   location (`fy_node_get_tag_token`) and a token's *end* mark are
   natural, cheap follow-ons if a concrete need ever shows up, same as
   `alibfyaml` notes for its own scope — not built here since nothing
   currently needs them.
9. **`[done]` Test/example parity audit**: a direct file-by-file
   comparison of `alibfyaml`'s `test/*.adb` against `tests/*.scm`
   turned up three gaps not called out as deliberate exclusions
   anywhere above — found after Phase 8, not planned for as part of
   it.

   **`test-path.scm`** (8 checks) ports `alibfyaml`'s own
   `test_path.adb` directly, reusing the existing `tests/navigate.yaml`
   fixture: `node-path` on the document root itself (`"/"`, not `""`,
   confirmed live despite the C header's own claim that
   `fy_node_get_path` returns `NULL` for the root — already noted in
   `slibfyaml-nodes.scm`'s own comment since Phase 2, re-confirmed
   here), a top-level scalar, a sequence element (`/tags/0`), a
   mapping node (`/server` — the concrete case `node-path` exists to
   cover that `node-location` structurally cannot, since a mapping
   node has no scalar token to hang a position off of), four levels of
   real nesting, a field inside one element of a sequence-of-mappings,
   and a full `node-by-path (node-path n) = n` round-trip between two
   different ways of reaching the same node. 8/8 checks pass, confirmed
   leak/error-free under valgrind.

   **`tests/example-syntax-error.scm`, `tests/example-value-error.scm`,
   `tests/example-missing-field.scm`** port `alibfyaml`'s own
   `example_syntax_error.adb`/`example_value_error.adb`/
   `example_missing_field.adb` line for line — worked demonstrations
   (plain `print`/`display` output, no `ok`/`FAIL` checks) rather than
   assertion tests, living in `tests/` alongside the `test-*.scm` files
   with an `example-` prefix rather than a separate `examples/`
   directory, matching `alibfyaml`'s own flat `test/` layout and
   letting them share `tests/`' existing fixtures and manual-build
   commands without new bookkeeping. New fixtures `tests/value_error.yaml`
   and `tests/missing_field.yaml` copied from `alibfyaml`'s own
   (underscore names kept, matching the existing `tests/anchors_cycle.yaml`
   precedent of preserving the Ada fixture's own name rather than
   converting to this repo's hyphenated `.scm` convention).

   - `example-syntax-error`: a pure parse error, no tree at all —
     reports the `(exn slibfyaml parse)` condition's own `'exn
     'message` gcc-format text directly, parsing the same malformed
     text from both a file and a string to show the one real
     difference (the `"file"` field: the real path vs.
     `document-parse-string`'s fixed `"(string-in-memory)"` override).
     Confirmed live output matches the Ada original's shape exactly
     (`malformed.yaml:3:1: error: flow sequence without a closing
     bracket`, same text again under the string-in-memory label).
   - `example-value-error`: a value that parses fine as YAML but fails
     a typed accessor — looks up the node with `node-by-path` *before*
     calling `node-integer-value` on it, so it's still in scope in the
     `condition-case` handler to report via `node-location` alongside
     the `(exn slibfyaml data)` condition's message, falling back to a
     location-less message for a node with no location at all. Confirmed
     live: `value_error.yaml:2:8: error: not a valid integer: "banana"`,
     same again from a string under `(string-in-memory)`.
   - `example-missing-field`: a genuinely different case from
     `example-value-error` — the key is simply absent, so there is no
     node/token for it at all and `node-location` has nothing to
     report a position for. Reports three ways: `node-location` alone
     (approximated via the nearby sibling `"name"` field every entry
     has, clearly labeled "near"), `node-path` alone (exact and always
     available — the *enclosing mapping's* own path plus the missing
     key's name, e.g. `/1/count`, something `node-location`
     fundamentally cannot produce for an absent key), and both
     together. Confirmed live against `missing_field.yaml`'s "beta"
     entry (index 1, 0-based): all three report forms match the Ada
     original's shape.

   All three confirmed leak/error-free under valgrind, including
   through their deliberate failure paths (the whole point of each).

   **`test_text_io.adb`** is not ported, and after investigating it's
   a closed question rather than a deferred one: it exercises
   `Libfyaml.Documents.Text_IO.Parse`, which reaches libfyaml's
   `fy_document_build_from_fp` (a raw C `FILE *`) by pulling the
   underlying C stream out of an open `Ada.Text_IO.File_Type` via
   `Ada.Text_IO.C_Streams` — itself a GNAT-specific extension, not
   portable Ada, precisely because Ada has no portable way to get a
   `FILE *` out of a `File_Type` either. CHICKEN's situation is
   actually worse, not just differently awkward: a CHICKEN port is not
   generally backed by a libc `FILE *` at all (CHICKEN 5's own file
   I/O goes through its own buffered layer over a POSIX file
   descriptor, not stdio), so there is no portable "get me the
   underlying `FILE *`" trick available even as an unportable escape
   hatch the way GNAT provides one — `fy_document_build_from_fp` is
   not bound in `slibfyaml-thin.scm` and adding it would need new,
   platform-specific FFI surface (e.g. `fdopen` over a raw fd obtained
   some other way) for comparatively little gain. Decided not to add
   it: `Ada.Text_IO.C_Streams.Parse`'s own doc comment already notes
   that `fy_document_build_from_fp` isn't real streaming anyway —
   confirmed live, a single call typically reads the *entire*
   remaining file in one internal `fread()`, regardless of how many
   documents worth of bytes that is — so an already-open CHICKEN port
   can get the same effective behavior today with no new binding
   surface at all: `(document-parse-string (read-string #f port))`,
   confirmed live to work identically against both a string port and a
   real open file port. That composition is the documented idiom for
   this case (see README.md) rather than a new `document-parse-port`
   entry point.
10. **Packaging**: finalize `.egg` metadata, license, README examples
    matching the finished API, submit to CHICKEN's egg index if
    desired.

Each phase should leave the tree in a state where its own test file(s)
pass under valgrind before moving to the next phase — not deferred to
a final polish pass, per the lesson `alibfyaml`'s own history already
paid for once.
