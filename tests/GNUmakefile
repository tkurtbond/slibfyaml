# tests/GNUmakefile
#
# Builds, runs, and cleans up every tests/*.scm test and example
# program via the manual csc-only inner loop documented in
# ../AGENTS.md's Build section (module .o's compiled once at the repo
# root, then linked per test program) -- this just codifies those
# commands rather than requiring them typed by hand.
#
# Every compile and every test/example run is capped the same way
# ../AGENTS.md's OOM safety section requires everywhere else in this
# repo (a previous agent session here was killed outright by the OOM
# killer, three times) -- do not remove the ulimit/timeout wrapping
# below to "simplify" this file.
#
# Targets, in the order they're meant to be used:
#   build (default) -- compile every test and example program
#   test            -- build, then run every test and example program
#   clean           -- remove the compiled test/example binaries
#
# Run from within tests/ (`make` or `make -C tests`), same as the
# manual commands in AGENTS.md -- `(include "check.scm")` resolves
# relative to the working directory at compile time, not this
# Makefile's own location.

ROOT := ..
CSC := csc

COMPILE_CAP := bash -c 'ulimit -v 4000000; exec timeout 60 "$$@"' --
RUN_CAP     := bash -c 'ulimit -v 2000000; exec timeout 30 "$$@"' --

# ---------------------------------------------------------------
# Test/example programs, grouped by which library .o's they need to
# link against (mirrors each file's own (import ...) forms) and by
# whether they use tests/check.scm's ok/FAIL convention (the three
# example-*.scm programs don't -- they're worked demonstrations, not
# assertion tests; see AGENTS.md's Test section).
# ---------------------------------------------------------------

THIN_ONLY_PROGS := test-thin
CORE_PROGS      := test-quickstart test-navigate test-scalars test-mutate \
                   test-anchors test-location test-parse-errors test-path \
                   test-port-io
STREAM_PROGS    := test-streams test-buffer-lifetime
SCHEME_PROGS    := test-scheme
EXAMPLE_PROGS   := example-syntax-error example-value-error example-missing-field

CHECK_PROGS := $(THIN_ONLY_PROGS) $(CORE_PROGS) $(STREAM_PROGS) $(SCHEME_PROGS)
ALL_PROGS   := $(CHECK_PROGS) $(EXAMPLE_PROGS)

.PHONY: build test clean

build: $(ALL_PROGS)

test: build
	@status=0; \
	for p in $(CHECK_PROGS); do \
		echo "=== $$p ==="; \
		$(RUN_CAP) ./$$p || status=1; \
	done; \
	for p in $(EXAMPLE_PROGS); do \
		echo "=== $$p (worked example -- a nonzero exit is its own deliberate demonstration, not a failure) ==="; \
		$(RUN_CAP) ./$$p || true; \
	done; \
	exit $$status

clean:
	$(RM) $(ALL_PROGS)

# ---------------------------------------------------------------
# Library module object files, in dependency order -- same -unit/-uses
# chain as AGENTS.md's Build section documents, expressed as make
# rules instead of typed by hand. Left in the repo root (not tests/),
# same as the manual workflow.
# ---------------------------------------------------------------

THIN_OBJ    := $(ROOT)/slibfyaml-thin.o
BASE_OBJ    := $(ROOT)/slibfyaml.o
NODES_OBJ   := $(ROOT)/slibfyaml-nodes.o
DOCS_OBJ    := $(ROOT)/slibfyaml-documents.o
STREAMS_OBJ := $(ROOT)/slibfyaml-documents-streams.o
SCHEME_OBJ  := $(ROOT)/slibfyaml-scheme.o

$(THIN_OBJ): $(ROOT)/slibfyaml-thin.scm
	$(COMPILE_CAP) $(CSC) -unit slibfyaml-thin -c -J $< -o $@

$(BASE_OBJ): $(ROOT)/slibfyaml.scm
	$(COMPILE_CAP) $(CSC) -unit slibfyaml -c -J $< -o $@

$(NODES_OBJ): $(ROOT)/slibfyaml-nodes.scm $(THIN_OBJ) $(BASE_OBJ)
	$(COMPILE_CAP) $(CSC) -unit slibfyaml-nodes -uses slibfyaml-thin -uses slibfyaml -c -J $< -o $@

$(DOCS_OBJ): $(ROOT)/slibfyaml-documents.scm $(THIN_OBJ) $(NODES_OBJ) $(BASE_OBJ)
	$(COMPILE_CAP) $(CSC) -unit slibfyaml-documents -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml -c -J $< -o $@

$(STREAMS_OBJ): $(ROOT)/slibfyaml-documents-streams.scm $(THIN_OBJ) $(DOCS_OBJ) $(BASE_OBJ)
	$(COMPILE_CAP) $(CSC) -unit slibfyaml-documents-streams -uses slibfyaml-thin -uses slibfyaml-documents -uses slibfyaml -c -J $< -o $@

$(SCHEME_OBJ): $(ROOT)/slibfyaml-scheme.scm $(NODES_OBJ) $(DOCS_OBJ) $(STREAMS_OBJ)
	$(COMPILE_CAP) $(CSC) -unit slibfyaml-scheme -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml-documents-streams -c -J $< -o $@

LIB_OBJS := $(THIN_OBJ) $(BASE_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(STREAMS_OBJ) $(SCHEME_OBJ)

# ---------------------------------------------------------------
# Test/example program link rules, one static pattern rule per group
# above -- same csc invocation shape as AGENTS.md's own
# test-quickstart example, generalized.
# ---------------------------------------------------------------

$(THIN_ONLY_PROGS): %: %.scm check.scm $(THIN_OBJ)
	$(COMPILE_CAP) $(CSC) -uses slibfyaml-thin \
	  $< $(THIN_OBJ) -o $@ -L -lfyaml -I $(ROOT)

$(CORE_PROGS): %: %.scm check.scm $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ)
	$(COMPILE_CAP) $(CSC) -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml \
	  $< $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ) -o $@ -L -lfyaml -I $(ROOT)

$(EXAMPLE_PROGS): %: %.scm $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ)
	$(COMPILE_CAP) $(CSC) -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml \
	  $< $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ) -o $@ -L -lfyaml -I $(ROOT)

$(STREAM_PROGS): %: %.scm check.scm $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ) $(STREAMS_OBJ)
	$(COMPILE_CAP) $(CSC) -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml -uses slibfyaml-documents-streams \
	  $< $(THIN_OBJ) $(NODES_OBJ) $(DOCS_OBJ) $(BASE_OBJ) $(STREAMS_OBJ) -o $@ -L -lfyaml -I $(ROOT)

$(SCHEME_PROGS): %: %.scm check.scm $(LIB_OBJS)
	$(COMPILE_CAP) $(CSC) -uses slibfyaml-thin -uses slibfyaml-nodes -uses slibfyaml-documents -uses slibfyaml -uses slibfyaml-documents-streams -uses slibfyaml-scheme \
	  $< $(LIB_OBJS) -o $@ -L -lfyaml -I $(ROOT)
