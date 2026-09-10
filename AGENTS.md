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

**Manually, for a single module + test file** (faster inner loop than a
full `chicken-install` per edit):

```sh
csc -unit slibfyaml-thin -c -J slibfyaml-thin.scm -o slibfyaml-thin.o
csc -uses slibfyaml-thin tests/test-thin.scm slibfyaml-thin.o -o test-thin -L -lfyaml
./test-thin
```

Both `-unit slibfyaml-thin` (so the compiled module doesn't emit its own
`main`/`C_toplevel` and collide with the test program's) and `-J` (so a
`.import.scm` is actually emitted for `(module (slibfyaml thin) ...)`'s
list-form name to be importable elsewhere) are required — found by
trial, not obvious from `csc -help` alone. Omitting `-unit` fails at
link time with "multiple definition of `C_toplevel`"; omitting `-J`
fails at compile time of the importing file with "cannot import from
undefined module".

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

```sh
csc -unit slibfyaml-thin -c -J slibfyaml-thin.scm -o slibfyaml-thin.o
csc -uses slibfyaml-thin tests/test-thin.scm slibfyaml-thin.o -o test-thin -L -lfyaml
./test-thin
```

Run under both CHICKEN versions by prefixing with the other install's
`bin/` (e.g. `/usr/local/sw/versions/chicken/6.0.0/bin/csc ...`) —
confirmed identical output under both for `test-thin`.

### Valgrind for anything touching document/node lifetime

Not optional polish — see PLAN.md's Memory model section and
`alibfyaml`'s own AGENTS.md for why (every real lifetime bug in that
sibling project surfaced as a test that *passed* while quietly reading
freed or premature memory). `test-thin` itself is confirmed leak- and
error-free under:

```sh
valgrind --leak-check=full --show-leak-kinds=definite,indirect --error-exitcode=99 ./test-thin
```

Run this on any test that creates/destroys a document, builds a buffer
passed to `fy_document_build_from_string`/`fy_parser_set_string`, or
touches `document-destroy!`/a finalizer, before considering the change
done.

## Layout

- `slibfyaml-thin.scm` — `(slibfyaml thin)`: 1:1 `foreign-lambda`
  imports, no ownership/error-checking policy. Binds only the C
  functions the thick layers actually need (confirmed present in the
  system libfyaml header — see PLAN.md's "C function surface"), not the
  full library speculatively.
- `slibfyaml.egg` — egg-information. One `extension` component per
  module currently implemented; add a new component when a new module
  (`slibfyaml.nodes`, `slibfyaml.documents`, ...) is actually written,
  not ahead of it.
- `tests/` — one standalone program per concern; see Test above.
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
