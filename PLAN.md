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

Design:

```scheme
;; (slibfyaml documents), sketch
(define-record-type document
  (make-document handle owned-buffer live?)
  document?
  (handle       document-handle set-document-handle!)
  (owned-buffer document-owned-buffer)
  (live?        document-live? set-document-live?!))

;; (slibfyaml nodes), sketch
(define-record-type node
  (make-node handle owner)         ; owner: the document this node's
  node?                            ; validity is tied to, or #f for
  (handle handle-of)               ; null-node / not-yet-attached
  (owner  node-owner))             ; freshly-built nodes (see below)
```

- Every accessor in `(slibfyaml nodes)` starts by calling a shared
  `(check-node-live! n)` helper: raises `(exn slibfyaml use-after-free)`
  if `(node-owner n)` is truthy and `(document-live? (node-owner n))`
  is `#f`. `null-node` and any node with no owner (see below) skip the
  liveness check and fall through to the existing `Is_Valid`-equivalent
  null-handle check instead — the two checks are independent, not
  layered.
- `document-destroy!` sets `live? → #f` on its record *before* calling
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
- Cost: one extra field on `node` (a reference to its owning
  `document`, not a copy of the live-flag — reading through the
  reference means one flag flip in `document-destroy!` invalidates
  every `node` drawn from that document at once) and one branch per
  accessor call. Negligible next to the FFI call itself.
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
stream, not just the first — fixing `yaml` egg's actual limitation
(`yaml-load` collapses its parse seed to `(car seed)` on
`document-end`, so it can only ever return the first document) without
inheriting `libyaml` egg's awkward fix for the same problem (its
`yaml->ss` returns a *callable* you invoke with a document index or
`-1` for "all of them," rather than just handing back the data).

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
  `test-location`, `test-path`.
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

## Phased roadmap

1. **Skeleton**: `.egg` file, `(slibfyaml thin)` with the full confirmed
   C function list bound (no logic yet), builds and links against
   system `pkg-config libfyaml` under both
   `/usr/local/sw/versions/chicken/5.4.0` and `.../6.0.0` — establish
   the dual-version build/test habit here, not later. Also the point
   at which to resolve the two "not yet checked" CHICKEN 6 items above
   (egg-index absence of a prior YAML egg, exact `.egg`/egg-information
   requirements for 6).
2. **Read-only parse + navigate**: `document-parse-string`/
   `-parse-file` (with the copy-always buffer strategy from day one,
   not retrofitted), `document-root`, `node-kind`/predicates,
   `node-scalar-value`, `node-length`/`node-item`, `node-value`/
   `node-has-key?`, `node-iterate-items`/`node-iterate-pairs`, `node-by-path`/
   `node-path`. Enough to port `test-quickstart` and `test-navigate`.
3. **Typed scalars**: the full `node-integer-value`/etc. family, core
   schema + the two extensions, `test-scalars` exhaustive coverage.
4. **Build + emit + mutate**: `document-create-*`, `document-set-root!`,
   `document-insert-at!` (with unconditional-consumption discipline),
   `node-append!`/`node-append-pair!`, `document->yaml-string`/
   `-write-to-file!`. `test-mutate`.
5. **Anchors/resolve**: `document-resolve!`, `node-alias?`, `node-tag`,
   `resolve-anchors?` on parse. `test-anchors`.
6. **Multi-document streaming**: `(slibfyaml documents streams)`, the
   no-recovery-after-parse-error behavior, buffer-sharing via the
   refcounted-copy design. `test-streams`, `test-buffer-lifetime`.
7. **Value-materializing API**: `(slibfyaml scheme)` — `node->scheme`,
   `load-string`/`load-file`, built on phases 2/3/6 above (needs typed
   scalars and streaming already in place). `test-scheme`.
8. **Diagnostics polish**: gcc-style `Parse_Error` formatting,
   `node-location`/`node-has-location?`, `test-parse-errors`/
   `test-location`.
9. **Packaging**: finalize `.egg` metadata, license, README examples
   matching the finished API, submit to CHICKEN's egg index if
   desired.

Each phase should leave the tree in a state where its own test file(s)
pass under valgrind before moving to the next phase — not deferred to
a final polish pass, per the lesson `alibfyaml`'s own history already
paid for once.
