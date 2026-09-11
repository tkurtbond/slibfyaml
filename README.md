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

**Status: Phases 1-9 done** (skeleton; read-only parse + navigate;
typed scalars; build + emit + mutate; anchors/resolve; multi-document
streaming; value-materializing API; diagnostics polish; test/example
parity audit) — see
`PLAN.md`'s Phased roadmap for each phase's own writeup. In short:
parsing (`document-parse-string`/`-parse-file`), full read-only tree
navigation, all seven condition kinds
(`parse`/`use-after-free`/`missing-key`/`data`/`emit`/`consumed`/
`resolve`, `data` now carrying `'line`/`'column` alongside `'path`
where a location is available), the full typed-scalar family (core
schema plus the `0b`/`_` extensions), building/mutating/emitting a
document (`document-create-*`/`node-append!`/`node-append-pair!`/
`document-insert-at!`/`document->yaml-string`/`-write-to-file!`),
anchor/alias/merge-key resolution (`document-resolve!`, `node-alias?`,
`node-tag`), multi-document streaming (`(slibfyaml documents streams)`,
including the refcounted buffer-sharing fix a document drawn from a
string-backed stream needs to outlive that stream safely), the
value-materializing convenience API (`(slibfyaml scheme)`'s
`node->scheme`/`load-string`/`load-file`), and source-location access
(`node-location`/`node-has-location?`, plus gcc-style
`"file:line:col: error: ..."` parse-error formatting, done since Phase
2) all work end to end. Confirmed via `tests/test-*.scm` (one file per
concern, 12 files, all passing and leak/error-free under valgrind —
including through every deliberate failure path each one exercises,
and one genuinely new libfyaml bug found and worked around along the
way, not just bugs `alibfyaml` had already found — see PLAN.md's Phase
7 writeup) plus three worked `tests/example-*.scm` demonstrations
(gcc-style diagnostics on a syntax error, a typed-value error, and a
missing-required-key case shown via `node-location`, `node-path`, and
both together — ported from `alibfyaml`'s own `test/example_*.adb`,
see PLAN.md's Phase 9 writeup), under both CHICKEN 5.4.0 and 6.0.0.
Remaining: packaging polish — see `PLAN.md`'s Phased roadmap.

Parsing from an already-open CHICKEN port (a file the caller opened
itself, `(current-input-port)`, etc.) has no dedicated entry point —
`document-parse-string`/`-parse-file` cover the string/path cases;
for a port, read it fully first: `(document-parse-string (read-string
#f port))`. See PLAN.md's Phase 9 writeup for why this, not a new
`document-parse-port`, is the documented idiom here (libfyaml's own
`fy_document_build_from_fp` isn't real streaming either — it typically
reads the whole remaining file in one internal `fread()` regardless of
document count — and CHICKEN has no portable way to obtain a `FILE *`
from an arbitrary port to bind it in the first place).

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
- `slibfyaml.scm` — **done.** All seven condition kinds exist:
  `parse`/`use-after-free` (Phase 2), `missing-key`/`data` (Phase 3),
  `emit`/`consumed` (Phase 4), `resolve` (Phase 5).
- `slibfyaml-nodes.scm` — **done.** `node`: a cheap, non-owning handle
  onto a tree node, with owner-liveness tracking (a use-after-free on a
  destroyed document's node raises a condition instead of reading freed
  memory — see PLAN.md's Memory model section, one of the places this
  binding's design goes beyond `alibfyaml`'s own Ada contract) and,
  since Phase 4, consumption tracking too (a node already handed to
  `document-insert-at!` raises `consumed` on further use, the same
  way). Typed scalar accessors (Phase 3), mutation (`node-append!`
  etc., Phase 4), anchors/tags (`node-alias?`/`node-tag`, Phase 5), and
  source location (`node-location`/`node-has-location?`, Phase 8) all
  live here too.
- `slibfyaml-documents.scm` — **done.** `document`: the owner of a
  parsed tree, with explicit `document-destroy!` (idempotent) plus a
  GC finalizer as a backstop, never RAII (CHICKEN has none). A
  refcounted `buffer-ref` (Phase 6) backs every document's copied input
  buffer uniformly, shared with a document-stream and every document
  drawn from it where that's genuinely needed. Building/mutating/
  emitting (Phase 4) and `document-resolve!` (Phase 5) live here too.
- `slibfyaml-documents-streams.scm` — **done.** Multi-document YAML
  streams built on libfyaml's separate streaming-parser API — a
  document-stream owns its own `fy_parser`/`fy_diag` and a read-ahead
  cache; a stream opened from a string shares its buffer-ref with every
  document drawn from it, so such a document safely outlives the
  stream it came from (`tests/test-buffer-lifetime.scm` is the
  dedicated regression test for exactly this, ported from a real bug
  `alibfyaml` found the hard way with valgrind).
- `slibfyaml-scheme.scm` — **done.** The value-materializing
  convenience API (`node->scheme`, `load-string`, `load-file`) — a pure
  consumer of the modules above, no new C calls or condition kinds of
  its own. Finding this phase's own test surfaced: a genuinely new
  (not `alibfyaml`-inherited) libfyaml bug, an uninitialized token
  field its own streaming parser can leave behind, worked around in
  `node-null-value?` — see PLAN.md's Phase 7 writeup.
- `tests/` — one test file per concern, ported from `alibfyaml`'s test
  suite where the same case applies, plus three `example-*.scm` worked
  demonstrations (gcc-style diagnostics, not `check`-style assertions)
  ported from `alibfyaml`'s own `test/example_*.adb` (Phase 9).
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
