# slibfyaml

A CHICKEN Scheme egg (targeting CHICKEN 5.4.0, with CHICKEN 6 support
on a best-effort basis — see PLAN.md's "Target CHICKEN version(s)")
binding to [libfyaml](https://github.com/pantoniou/libfyaml)'s
core parser/emitter/document API, following the same design as the
[alibfyaml](https://github.com/tkurtbond/alibfyaml) Ada binding to the same library:
parse YAML/JSON into a document tree, navigate and mutate it with cheap
handles, emit it back out — rather than converting the whole document
into a native Scheme value up front the way the existing `yaml` and
`libyaml` Chicken eggs do.

**Status: Phase 2 (read-only parse + navigate) done.** Parsing
(`document-parse-string`/`-parse-file`), read-only tree navigation
(`node-kind`/predicates, `node-scalar-value`, `node-length`/`node-item`,
`node-value`/`node-has-key?`, `node-iterate-items`/`node-iterate-pairs`,
`node-by-path`/`node-path`), and the `use-after-free`/`parse` error
conditions all work end to end, confirmed via `tests/test-quickstart.scm`
and `tests/test-navigate.scm` (both passing, both leak/error-free under
valgrind — including through the deliberate parse-failure and
use-after-free paths) under both CHICKEN 5.4.0 and 6.0.0. No typed
scalars yet (every check so far compares raw scalar text), and nothing
past read-only navigation (mutation, emit, streaming, the
value-materializing API) exists yet — see `PLAN.md`'s Phased roadmap.

## Scope

Covers document lifecycle, node predicates/navigation, sequence/mapping
access and construction, path lookup, emission, and diagnostics
collection, mirroring `alibfyaml`'s scope exactly. Intentionally does
**not** cover:

- **Generics** (`fy_generic`): libfyaml's Python-`dict`/`list`-like
  sum-type value model, built on C11 `_Generic`/variadic macros with no
  plain-C-callable equivalent to bind.
- **Reflection**: typed YAML <-> C struct serdes driven by libclang or
  packed metadata — no analogous typed-struct target in Scheme.
- **scanf/printf-style variadic entry points** (`fy_document_scanf`,
  `fy_node_buildf`, ...): not callable through CHICKEN's FFI either.

## Why this instead of `yaml` or `libyaml`

The existing Chicken YAML eggs (see the sibling comparison note this
project's author keeps) both materialize a parsed document into plain
Scheme data (alist/list/scalar, or a wrapped-alist/vector/scalar) in one
shot. That's simpler for a small config file, but offers no lazy
access, no path queries, and no in-place mutation of a parsed tree.
`slibfyaml` instead exposes a `document` (owns the parsed/built libfyaml
tree) and cheap `node` handles into it, navigated by predicate and
accessor calls — the same tradeoff `alibfyaml` makes in Ada, adapted to
Scheme's GC instead of Ada's RAII. See `PLAN.md` for the full rationale
and the memory-safety issues this tradeoff raises in a garbage-collected
host.

## Also: plain Scheme data, like `yaml`/`libyaml`, but multi-document

Handles aren't always wanted — sometimes you just want a config file as
an alist. `(slibfyaml scheme)` decodes a document (or any `node`) into
plain Scheme data the same shape `yaml` egg's `yaml-load` returns
(mapping → alist, sequence → list, scalar → resolved value), but
`load-string`/`load-file` always return a **list of decoded documents**
— fixing `yaml-load`'s actual limitation (it can only ever return the
first document of a multi-document stream) without `libyaml` egg's
awkward fix for the same gap (its `yaml->ss` hands back a callable you
invoke with a document index, rather than the data itself). This layer
is a pure consumer of the handle-based core below it — no separate
parser, no separate typed-scalar logic. See PLAN.md's
"Value-materializing convenience API" section for the full design.

## Layout

- `slibfyaml-thin.scm` — **done.** Low-level 1:1 `foreign-lambda`
  imports over libfyaml's exported C symbols. No ownership or
  error-checking policy.
- `slibfyaml.scm` — **done so far.** Condition types: `parse` and
  `use-after-free` exist; `emit`, `missing-key`, `data`, `resolve`,
  `consumed` are added in the phases that introduce the operations
  that raise them.
- `slibfyaml-nodes.scm` — **done for read-only access.** `node`: a
  cheap, non-owning handle onto a tree node, with owner-liveness
  tracking (a use-after-free on a destroyed document's node raises a
  condition instead of reading freed memory — see PLAN.md's Memory
  model section, the one place this binding's design goes beyond
  `alibfyaml`'s own Ada contract). Mutation (`node-append!` etc.) is
  Phase 4.
- `slibfyaml-documents.scm` — **done for read-only access.**
  `document`: the owner of a parsed tree, with explicit
  `document-destroy!` (idempotent) plus a GC finalizer as a backstop,
  never RAII (CHICKEN has none). Building/mutating/emitting a document
  is Phase 4.
- `slibfyaml-documents-streams.scm` — multi-document YAML streams.
- `slibfyaml-scheme.scm` — the value-materializing convenience API
  (`node->scheme`, `load-string`, `load-file`).
- `tests/` — one test file per concern, ported from `alibfyaml`'s test
  suite where the same case applies.
- `PLAN.md` — design rationale, decisions, and open questions.

## Building

```sh
pkg-config --exists libfyaml && pkg-config --modversion libfyaml
chicken-install
```

Confirmed working end to end (build, install, import) under both
CHICKEN 5.4.0 and 6.0.0 on this machine — the system-packaged libfyaml
(labeled `0.8`) exports every symbol this binding needs, the same
situation `alibfyaml` found on the same machine. See AGENTS.md for the
exact commands, including the faster manual `csc`-only inner loop used
while developing.

## License

Undecided — see PLAN.md open questions. (`alibfyaml` is unlicensed at
time of writing; the existing `yaml` and `libyaml` Chicken eggs are
BSD-style and MIT respectively.)
