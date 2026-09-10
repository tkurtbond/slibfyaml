# slibfyaml

A CHICKEN Scheme 5 egg binding to [libfyaml](https://github.com/pantoniou/libfyaml)'s
core parser/emitter/document API, following the same design as the
[alibfyaml](https://codeberg.org/) Ada binding to the same library:
parse YAML/JSON into a document tree, navigate and mutate it with cheap
handles, emit it back out — rather than converting the whole document
into a native Scheme value up front the way the existing `yaml` and
`libyaml` Chicken eggs do.

**Status: design phase.** No code has been written yet — see `PLAN.md`
for the full design and open questions before starting implementation.

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

## Layout (planned)

- `fyaml-thin.scm` — low-level 1:1 `foreign-lambda` imports over
  libfyaml's exported C symbols. No ownership or error-checking policy.
- `fyaml.scm` — condition types (`parse`, `emit`, `missing-key`, `data`,
  `resolve`).
- `fyaml-nodes.scm` — `node`: a cheap, non-owning handle onto a tree
  node.
- `fyaml-documents.scm` — `document`: the owner of a parsed or
  freshly-built tree, with explicit `document-destroy!` plus a
  GC finalizer as a backstop.
- `fyaml-documents-streams.scm` — multi-document YAML streams.
- `tests/` — one test file per concern, ported from `alibfyaml`'s test
  suite where the same case applies.
- `PLAN.md` — design rationale, decisions, and open questions.

## Building (planned)

```sh
pkg-config --exists libfyaml && pkg-config --modversion libfyaml
chicken-install
```

See PLAN.md for the version/ABI note — the system-packaged libfyaml on
this machine (labeled `0.8`) has been confirmed to already export every
symbol this binding needs, the same situation `alibfyaml` found on the
same machine.

## License

Undecided — see PLAN.md open questions. (`alibfyaml` is unlicensed at
time of writing; the existing `yaml` and `libyaml` Chicken eggs are
BSD-style and MIT respectively.)
