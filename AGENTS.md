# AGENTS.md

Handle/tree binding to libfyaml for CHICKEN Scheme, porting `alibfyaml`'s
Ada design. See README.md for scope, PLAN.md for design history and open
questions. This file is operational notes for an agent working in this
repo, not a design doc.

## Build

Two ways, both confirmed working under both target CHICKEN versions
(`/usr/local/sw/versions/chicken/5.4.0` and `.../6.0.0` on this machine
— see PLAN.md's "Target CHICKEN version(s)"):

**Via the real `.egg` file** (what an actual install does):

```sh
CHICKEN_INSTALL_PREFIX=/tmp/some-scratch-prefix chicken-install
```

Use a scratch `CHICKEN_INSTALL_PREFIX` for iterating, rather than
installing into the shared toolchain on every change — confirmed this
round-trips correctly (build, install, then `csi -e '(import (slibfyaml
thin)) ...'` against `CHICKEN_REPOSITORY_PATH=$PREFIX/lib/chicken/<N>`,
where `<N>` is CHICKEN's binary-version directory, `11` for 5.4.0 and
`12` for 6.0.0 on this machine — found live, not documented anywhere
obvious).

**Manually, module by module** (faster inner loop than a full
`chicken-install` per edit) — compile every module the test needs, in
dependency order, then link:

```sh
csc -unit slibfyaml-thin -c -J slibfyaml-thin.scm -o slibfyaml-thin.o
csc -unit slibfyaml -c -J slibfyaml.scm -o slibfyaml.o
csc -unit slibfyaml-nodes -uses slibfyaml-thin -uses slibfyaml -c -J slibfyaml-nodes.scm -o slibfyaml-nodes.o
csc -unit slibfyaml-documents -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml -c -J slibfyaml-documents.scm -o slibfyaml-documents.o
```

Then, from `tests/` (see the `include` note under Test below for why
`tests/` specifically):

```sh
csc -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml \
  test-quickstart.scm ../slibfyaml-thin.o ../slibfyaml-nodes.o ../slibfyaml-documents.o ../slibfyaml.o \
  -o test-quickstart -L -lfyaml -I ..
./test-quickstart
```

Three flags matter here, none obvious from `csc -help` alone, all found
by trial:

- **`-unit <name>`** on every module compile — otherwise it emits its
  own `main`/`C_toplevel` and collides with whatever links against it
  ("multiple definition of `C_toplevel`").
- **`-J`** on every module compile — otherwise no `.import.scm` is
  emitted at all for `(module (slibfyaml ...) ...)`'s list-form name,
  and nothing can `(import (slibfyaml ...))` it ("cannot import from
  undefined module").
- **`-uses <name>` on the module's *own* compile, for every module it
  itself imports** — not just on the final program's compile. A
  module's own internal `(import (slibfyaml thin))` etc. only resolves
  statically if the compiler already knew about that dependency *when
  that module itself was compiled*; otherwise the compiled code falls
  back to a runtime `load-extension` call (i.e., dynamic loading, which
  isn't set up for a plain multi-`.o` static link) and fails at
  *runtime* with "cannot load extension: slibfyaml" — confirmed live by
  hitting exactly this once while wiring up `(slibfyaml nodes)` and
  `(slibfyaml documents)`, and fixing it by moving `-uses` from the
  final test-program compile to each module's own compile step, as
  shown above.

`-I ..` on the final link step (both examples above) so the compiler
finds `../slibfyaml-thin.o`'s sibling `.import.scm` files, which live
in the repo root alongside the `.o`s, not in `tests/`.

**Note on `chicken-install` *not* needing the `-uses` dance above**:
tried adding a `component-dependencies` field per extension in
`slibfyaml.egg`, on the assumption it would be required the same way
manual `-uses` is — rebuilt into a scratch prefix both with and without
it and got an identical, working result either way, so it was removed
rather than left in unverified. The likely reason: `chicken-install`
builds each component as its own dynamically-loaded extension (`.so`),
and a consumer's `(import (slibfyaml documents))` resolves that
extension's own internal dependency on `(slibfyaml nodes)`/`(slibfyaml
thin)`/`(slibfyaml)` via the ordinary repository-based dynamic-load
mechanism at runtime — the static-linking-specific problem above simply
doesn't arise on that path. See `slibfyaml.egg`'s own comment for this,
so a future edit doesn't reintroduce the field on the same wrong
assumption.

One more thing confirmed only by testing an actual consumer program
against a `chicken-install`ed scratch prefix, not by reasoning about it:
**`CHICKEN_REPOSITORY_PATH` *replaces* the default repository search
path, it does not add to it** — setting it to only the scratch prefix
hides CHICKEN's own core syntax/units (e.g. `chicken.foreign`) and
produces a confusing "cannot import from undefined module
chicken.foreign" at a *consuming* program's compile time that has
nothing to do with `slibfyaml` itself. Combine both paths with `:`:

```sh
CHICKEN_REPOSITORY_PATH="$PREFIX/lib/chicken/<N>:$(chicken-install -repository)"
```

using that combined value for both the consumer's compile *and* its
run (the run needs it too, separately — a `.so` extension is
`dlopen`'d at runtime via the same repository lookup, not found via
`LD_LIBRARY_PATH`).

Link flags: `-L -lfyaml` (two separate arguments — `-lfyaml` as one
combined flag is rejected by `csc`'s own option parser, not passed
through). `pkg-config --libs libfyaml` on this machine reports plain
`-lfyaml` with no `-L<dir>` needed, which is why `slibfyaml.egg` hard-
codes it rather than shelling out to `pkg-config` via `custom-config` —
revisit if a future machine needs a non-standard libfyaml location (see
PLAN.md's Build/packaging section).

## Test

One file per concern (see PLAN.md's Testing plan), each a standalone
program using the ok/FAIL convention `alibfyaml` also uses: prints
`ok   - <label>` / `FAIL - <label>` per check, ends with "All checks
passed." or "<N> check(s) failed.", and exits nonzero on any failure.
The `check`/`check-summary-and-exit` helpers live once in
`tests/check.scm` and are pulled into every `test-*.scm` via
`(include "check.scm")` — a *textual* inclusion at compile time (not a
compiled module of its own; these are standalone test programs, not
part of the installed egg, so there's no separate unit/link bookkeeping
worth the ceremony for a three-line helper).

`(include "check.scm")` resolves relative to the current working
directory at compile time, not the including file's own directory —
either compile from within `tests/` (as the Build section's manual
example above does) or pass `-I tests` from the repo root instead;
confirmed both work identically (`-I` affects `include` resolution
too, not just where `.import.scm` files are looked up).

Run under both CHICKEN versions by prefixing every command with the
other install's `bin/` (e.g.
`/usr/local/sw/versions/chicken/6.0.0/bin/csc ...`) — confirmed
identical output under both for every test file that exists so far.

### Valgrind for anything touching document/node lifetime

Not optional polish — see PLAN.md's Memory model section and
`alibfyaml`'s own AGENTS.md for why (every real lifetime bug in that
sibling project surfaced as a test that *passed* while quietly reading
freed or premature memory). `test-thin` itself is confirmed leak- and
error-free under:

```sh
valgrind --leak-check=full --show-leak-kinds=definite,indirect --error-exitcode=99 ./test-thin
```

`test-quickstart`, `test-navigate`, and `test-scalars` are confirmed
leak/error-free the same way, including through the exception paths (a
deliberately malformed parse, a use-after-free triggered on purpose,
every `missing-key`/`data` condition `test-scalars` exercises) — those
paths are exactly where a missed `c-free`/double-`c-free` is easiest to
introduce (see `document-parse-string`'s own comment on why its
`handle-exceptions` wrapper exists), so they're not exempt from this
check just because they're *expected* to fail.

Run this on any test that creates/destroys a document, builds a buffer
passed to `fy_document_build_from_string`/`fy_parser_set_string`, or
touches `document-destroy!`/a finalizer, before considering the change
done.

## Layout

- `slibfyaml-thin.scm` — `(slibfyaml thin)`: 1:1 `foreign-lambda`
  imports, no ownership/error-checking policy. Binds only the C
  functions the thick layers actually need (confirmed present in the
  system libfyaml header — see PLAN.md's "C function surface"), not the
  full library speculatively. Also has a handful of small, mechanical,
  non-libfyaml-specific C-interop helpers (`c-malloc`, `size_t-ref`,
  `make-pointer-cell`, `decode-c-string`, `nul-terminated-c-string-at`)
  shared by every module built on top of it, added here rather than
  duplicated per module.
- `slibfyaml.scm` — `(slibfyaml)`: condition types
  (`raise-parse-error`, `raise-use-after-free` so far).
- `slibfyaml-nodes.scm` — `(slibfyaml nodes)`: `node`, a cheap
  non-owning handle. Deliberately does **not** import `(slibfyaml
  documents)` — see this file's own header comment for why (a shared
  liveness *box*, not a reference to the actual `document` record,
  breaks what would otherwise be a two-way module dependency).
- `slibfyaml-documents.scm` — `(slibfyaml documents)`: `document`, the
  owner of a parsed/built tree — explicit `document-destroy!` plus a
  `set-finalizer!` backstop, never RAII (CHICKEN has none).
- `slibfyaml.egg` — egg-information. One `extension` component per
  module currently implemented; add a new component when a new module
  (`slibfyaml.documents.streams`, `slibfyaml.scheme`) is actually
  written, not ahead of it. No intra-egg dependency declaration needed
  between components — see the file's own comment and the Build
  section's `component-dependencies` note above for why.
- `tests/` — one standalone program per concern; see Test above.
  `check.scm` is the shared ok/FAIL helper, `config.yaml`/`navigate.yaml`
  are fixtures copied from `alibfyaml`'s own `test/` directory for
  direct comparability between the two projects' test suites.
- `PLAN.md` — design history, confirmed findings, and open questions,
  organized by feature section — append to the relevant section rather
  than starting a new document, matching `alibfyaml`'s own convention.

## Conventions specific to this codebase

- **Never type a thin-layer parameter/return as `c-string` for anything
  libfyaml retains a pointer into past the call, or that isn't
  necessarily NUL-terminated at its intended length.** `c-string`
  marshaling in CHICKEN is transient (valid only for the duration of
  the call) and scans for a NUL terminator — wrong on both counts for
  e.g. `fy_node_get_scalar`/`fy_node_get_tag` (a zero-copy span that
  may have more non-NUL bytes after its intended end) or
  `fy_document_build_from_string`'s `str` (libfyaml keeps reading from
  it for the document's whole life). Use `c-pointer` and an explicit
  `size_t` length instead, decoded via `move-memory!` at the point
  something actually needs a Scheme string — see `slibfyaml-thin.scm`'s
  own header comment and `tests/test-thin.scm` for the pattern. A
  synchronous-only path/key argument (a file path, a mapping lookup
  key) has no such hazard and uses plain `c-string` instead.
- **Any `char *` libfyaml hands back ownership of** (`fy_node_get_path`,
  `fy_emit_document_to_string`) **must stay a raw `c-pointer` at the
  thin layer, never `c-string`.** Returning `c-string` copies into a
  fresh GC'd Scheme string immediately and the original `malloc`'d
  pointer is lost — nothing could ever call `c-free` on it. Convert to
  a Scheme string *and* free the original pointer at the point that
  actually happens, not inside the thin binding.
- **CHICKEN 6 hex string escapes need a trailing `;`** (`\x1b;`, not
  `\x1b`) — see PLAN.md's "Target CHICKEN version(s)". Avoid bare hex
  escapes in this codebase entirely rather than remembering the rule
  per literal.
- **`foreign-declare "#include <libfyaml.h>"` is per compilation unit,
  not shared across separately-compiled modules.** Any module using
  `foreign-value`/`foreign-lambda*` against a libfyaml enum or struct
  field needs its own `(foreign-declare "#include <libfyaml.h>")`, even
  though `slibfyaml-thin.scm` already has one — found by a real compile
  failure (`FYNT_SCALAR` undeclared) while writing `slibfyaml-nodes.scm`.
- **A `node`/`document`'s liveness check happens *inside* the
  accessor, called first thing, not left to the caller.** Every
  `(slibfyaml nodes)` accessor calls `check-node-live!` and every
  mutating-or-reading `(slibfyaml documents)` operation calls
  `check-document-live!` before touching the raw handle — this is the
  whole point of the owner-liveness design (see PLAN.md's Memory
  model section); a new accessor that skips this check reintroduces
  the exact use-after-free class of bug that design exists to close.
- **A parse failure must never leak the buffer `document-parse-string`
  copied its input into.** Nothing else takes ownership of that buffer
  if no `document` ever gets built (the failure happens inside
  `parse-common`, before a `document` record exists to hold it) — see
  `document-parse-string`'s `handle-exceptions` wrapper, added
  specifically to free it on that path before re-raising. Confirmed
  leak-free under valgrind, including through this exact path
  (`tests/test-quickstart.scm`'s deliberately-malformed-input check) —
  don't remove or bypass that wrapper when touching this function.
