###############################################################################
# lmbench — Per-App Sandbox Build (Template with heavy inline documentation)
#
# This Makefile is designed to be dropped into apps/<name>/ and used as a
# template for other apps. It implements the “build contract” summarized below:
#
# ─────────────────────────────────────────────────────────────────────────────
# THE BUILD CONTRACT (for readers who’ve never seen it before)
#
# 1) Per-app sandboxes
#    Each app lives under apps/<name>/ and owns its own:
#      - src/              : application sources
#      - out/              : compiled artifacts (.o, .wasm, .cwasm, .a)
#      - sysroot_overlay/  : “system-facing” headers/libs produced by this app
#
# 2) Read-only base sysroot
#    The app compiles *against* a pristine base sysroot via --sysroot=… and
#    -isystem/-L flags, but NEVER writes into it. That base sysroot stays clean.
#
# 3) Overlay is the only write target for “system” bits
#    Anything the app wants to expose to the world (headers, small libs,
#    stubs/shims) is written under sysroot_overlay/{usr/,}include and usr/lib.
#
# 4) Top-level orchestrator merges overlays into a scratch sysroot
#    The repo root has a script/Makefile target that:
#      a) builds each app (make -C apps/<name> all)
#      b) creates build/scratch-sysroot/
#      c) rsyncs the base sysroot into scratch
#      d) rsyncs each app’s sysroot_overlay/ into scratch (layered union)
#    No app writes directly to the base; only the orchestrator creates the
#    final “merged view” used for integration, linking, or tests.
#
# 5) Clean lifecycle
#      make all        : builds shims, lib, and programs into out/
#      make clean      : removes out/ but leaves sysroot_overlay/ intact
#      make distclean  : removes both out/ and sysroot_overlay/
#
# This file also includes a declarative shim system. Some legacy headers
# (e.g., SunRPC/TIRPC) aren’t present on WASI; we generate minimal forwarders
# or stubs into the overlay so the compiler can proceed. Add new shims to the
# SHIM_FORWARDERS list and re-run `make all`.
###############################################################################

SHELL := /bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# App-local layout (override via environment as needed)
APP              ?= lmbench            # purely informational
SRC_DIR          ?= src                # where .c live
OUT_DIR          ?= out                # where .o/.a/.wasm/.cwasm go
OVERLAY_DIR      ?= sysroot_overlay    # app’s local sysroot layer (headers/libs)

# Overlay include/lib roots. We support both usr/include and include to make
# downstream consumers agnostic to exact include search ordering.
OVERLAY_INC_MAIN := $(OVERLAY_DIR)/usr/include
OVERLAY_INC_ALT  := $(OVERLAY_DIR)/include
OVERLAY_LIB      := $(OVERLAY_DIR)/usr/lib

# Read-only base sysroot (produced by your glibc/WASI build scripts).
# We pass this to clang/ld with --sysroot and never write into it.
BASE_SYSROOT     ?= ../../src/glibc/sysroot

# ─────────────────────────────────────────────────────────────────────────────
# Toolchain roots (prefer overriding prefixes over leaf paths)
LLVM_PREFIX      ?= /home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04
BINARYEN_PREFIX  ?= /home/lind/lind-wasm/tools/binaryen
WASMTIME_DEFAULT := ../../src/wasmtime/target/release/wasmtime

# Tool executables (user may override; we normalize below)
CLANG    ?= $(LLVM_PREFIX)/bin/clang
WASM_OPT ?= $(BINARYEN_PREFIX)/bin/wasm-opt
WASMTIME ?= $(if $(wildcard $(WASMTIME_DEFAULT)),$(WASMTIME_DEFAULT),$(shell command -v wasmtime 2>/dev/null || echo /bin/false))
WANT_AOT ?= 1   # 1 = produce .cwasm with wasmtime compile if wasmtime exists; 0 = skip

# Archive/index tools (LLVM versions to match clang)
AR      ?= $(LLVM_PREFIX)/bin/llvm-ar
RANLIB  ?= $(LLVM_PREFIX)/bin/llvm-ranlib

# Tool path normalization: if someone exported a directory, convert to bin/<tool>.
# This prevents the classic “Is a directory” error when CLANG/WASM_OPT/AR/RANLIB
# are pointed at installation directories instead of the binaries.
ifneq ($(wildcard $(CLANG)/bin/clang),)
  CLANG := $(CLANG)/bin/clang
endif
ifeq ($(wildcard $(CLANG)),)
  CLANG := $(LLVM_PREFIX)/bin/clang
endif
ifneq ($(wildcard $(WASM_OPT)/bin/wasm-opt),)
  WASM_OPT := $(WASM_OPT)/bin/wasm-opt
endif
ifeq ($(wildcard $(WASM_OPT)),)
  WASM_OPT := $(BINARYEN_PREFIX)/bin/wasm-opt
endif
ifneq ($(wildcard $(AR)/llvm-ar),)
  AR := $(AR)/llvm-ar
endif
ifeq ($(wildcard $(AR)),)
  AR := $(LLVM_PREFIX)/bin/llvm-ar
endif
ifneq ($(wildcard $(RANLIB)/llvm-ranlib),)
  RANLIB := $(RANLIB)/llvm-ranlib
endif
ifeq ($(wildcard $(RANLIB)),)
  RANLIB := $(LLVM_PREFIX)/bin/llvm-ranlib
endif

# Target triple (switch to wasm32-wasi-threads and add -pthread only if your
# toolchain/runtime have threads enabled).
TARGET := wasm32-unknown-wasi

# Extra flags you can inject from CLI without modifying the file.
CFLAGS_EXTRA  ?=
LDFLAGS_EXTRA ?=

# Compiler flags:
#  - Reads from BASE_SYSROOT (sysroot + include paths)
#  - Also searches our overlay include roots so generated/staged headers resolve
COMMON_CFLAGS := -std=gnu89 --target=$(TARGET) -g -O2 \
                 --sysroot=$(BASE_SYSROOT) \
                 -isystem $(BASE_SYSROOT)/include/wasm32-wasi \
                 -isystem $(BASE_SYSROOT)/include \
                 -isystem $(OVERLAY_INC_MAIN) \
                 -isystem $(OVERLAY_INC_MAIN)/wasm32-wasi \
                 -isystem $(OVERLAY_INC_ALT) \
                 -isystem $(OVERLAY_INC_ALT)/wasm32-wasi \
                 $(CFLAGS_EXTRA)

# Linker flags:
#  - Links against base sysroot libs (read-only) and overlay libs (if present)
#  - Memory/exports configured for the runtime
COMMON_LDFLAGS := -L$(BASE_SYSROOT)/lib/wasm32-wasi \
                  -L$(OVERLAY_LIB) \
                  -Wl,--import-memory,--export-memory,--max-memory=67108864 \
                  -Wl,--export=__stack_pointer,--export=__stack_low \
                  $(LDFLAGS_EXTRA)

# ─────────────────────────────────────────────────────────────────────────────
# Source discovery
# We deliberately EXCLUDE the support sources (lib_*.c, getopt.c) from the
# “programs” list; they’ll be built into a static lib and linked into each test.
EXCLUDE_SRCS := getopt.c lat_usleep.c lib_*.c
SRC   := $(filter-out $(EXCLUDE_SRCS),$(notdir $(wildcard $(SRC_DIR)/*.c)))
WASM  := $(patsubst %.c,$(OUT_DIR)/%.wasm,$(SRC))
CWASM := $(patsubst %.wasm,%.cwasm,$(WASM))

# Support code providing benchmp/bandwidth/mygetopt/etc.
LIB_SRCS := $(wildcard $(SRC_DIR)/lib_*.c) $(SRC_DIR)/getopt.c
LIB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(OUT_DIR)/%.o,$(LIB_SRCS))
LIB_A    := $(OUT_DIR)/liblmbench.a

# ─────────────────────────────────────────────────────────────────────────────
# Shim forwarders
#
# Some legacy or platform-specific headers don’t exist on WASI. Instead of
# porting those subsystems, we generate forwarder or stub headers directly into
# our overlay so the compiler can proceed. This list is data-driven:
#
#   dest/header.h = dep1.h,dep2.h,...
#
# If the right side is empty (e.g., rpc/clnt.h=), we write a stub with only
# #pragma once. Generated files are emitted into BOTH overlay include roots:
#   sysroot_overlay/usr/include/<dest/header.h>
#   sysroot_overlay/include/<dest/header.h>
#
# To add a new shim: append a new “key=value” pair below and re-run `make all`.
SHIM_FORWARDERS := \
  rpc/rpc.h=rpc/clnt.h,rpc/svc.h \
  rpc/clnt.h= \
  rpc/svc.h= \
  rpc/types.h= \
  netconfig.h=rpc/netconfig.h \
  netdb.h=arpa/inet.h \
  resolv/resolv.h=arpa/nameser.h,netinet/in.h

# (Optional) If you ever want to export your local static lib for other apps:
# install-overlay-lib:
# 	mkdir -p $(OVERLAY_LIB)
# 	cp $(LIB_A) $(OVERLAY_LIB)/

# ─────────────────────────────────────────────────────────────────────────────
.PHONY: all build clean distclean overlay-check overlay-shims print-vars

# Default entry point: build everything in this app sandbox.
all: build

# Full build flow:
#  1) overlay-check   : verify tools, base sysroot, and create overlay roots
#  2) overlay-shims   : emit forwarder/stub headers into the overlay
#  3) $(OUT_DIR)      : ensure output dir exists
#  4) $(LIB_A)        : build support static library out/liblmbench.a
#  5) $(CWASM)        : build each program to .wasm and optional .cwasm
build: overlay-check overlay-shims $(OUT_DIR) $(LIB_A) $(CWASM)
	@echo "[✔] Build complete: $(OUT_DIR)"

# Ensure out/ exists (used by many rules)
$(OUT_DIR):
	mkdir -p $@

# Compile support objects to out/*.o (not installed into overlay by default)
$(OUT_DIR)/%.o: $(SRC_DIR)/%.c | $(OUT_DIR)
	$(CLANG) $(COMMON_CFLAGS) -c $< -o $@

# Archive support objects into out/liblmbench.a
# Linking programs will consume this archive locally; if you want it visible
# to other apps after orchestrator merge, add the install-overlay-lib rule above.
$(LIB_A): $(LIB_OBJS)
	$(AR) rcs $@ $(LIB_OBJS)
	$(RANLIB) $@

# Build each program:
#  - compile/link against base sysroot + our local static lib
#  - output stays in out/ (overlay remains just “system-facing” headers/libs)
$(OUT_DIR)/%.wasm: $(SRC_DIR)/%.c $(LIB_A)
	@echo "[*] Compiling $< → $@"
	$(CLANG) $(COMMON_CFLAGS) $< -o $@ $(COMMON_LDFLAGS) $(LIB_A) -lc

# Optional AOT cache via wasmtime. We keep .wasm regardless; .cwasm is a fast-start
# cache. If WASMTIME is unavailable or WANT_AOT=0, we skip and note it.
$(OUT_DIR)/%.cwasm: $(OUT_DIR)/%.wasm
	@echo "[*] Optimizing $<"
	$(WASM_OPT) --epoch-injection --asyncify -O2 --debuginfo $< -o $<
	@if [ "$(WANT_AOT)" = "1" ] && [ -x "$(WASMTIME)" ]; then \
		echo "[*] AOT-compiling $< → $@ using $(WASMTIME)"; \
		"$(WASMTIME)" compile $< -o $@; \
	else \
		echo "[!] Skipping AOT (WANT_AOT=$(WANT_AOT), WASMTIME=$(WASMTIME))"; \
		cp $< $@.wasm-skipped; \
	fi

# Sanity checks and overlay root creation:
#  - Verifies tool executables
#  - Verifies base sysroot has at least the expected key files
#  - Creates overlay include/lib roots (apps write only here)
overlay-check:
	@mkdir -p "$(OVERLAY_INC_MAIN)" "$(OVERLAY_INC_ALT)" "$(OVERLAY_LIB)"
	@if [ ! -x "$(CLANG)" ]; then echo "CLANG not executable: $(CLANG)"; exit 1; fi
	@if [ ! -x "$(WASM_OPT)" ]; then echo "WASM_OPT not executable: $(WASM_OPT)"; exit 1; fi
	@h1="$(BASE_SYSROOT)/include/wasm32-wasi/stdio.h"; \
	 l1="$(BASE_SYSROOT)/lib/wasm32-wasi/libc.a"; \
	 c1="$(BASE_SYSROOT)/lib/wasm32-wasi/crt1.o"; \
	 if [ ! -r "$$h1" ] || [ ! -r "$$l1" ] || [ ! -r "$$c1" ]; then \
	   echo "Missing base sysroot pieces (check BASE_SYSROOT):"; \
	   echo "  $$h1"; echo "  $$l1"; echo "  $$c1"; \
	   exit 1; \
	 fi

# Shim emission:
#  - For each entry in SHIM_FORWARDERS (“dest=dep1,dep2,...”), write a header
#    with #pragma once and the listed #include lines
#  - Generate into BOTH overlay include roots, making this overlay robust to
#    downstream include path preferences when overlays are merged by the
#    orchestrator into the scratch sysroot.
overlay-shims:
	@set -e; \
	for entry in $(SHIM_FORWARDERS); do \
		[ -n "$$entry" ] || continue; \
		hdr="$${entry%%=*}"; incs="$${entry#*=}"; \
		[ -n "$$hdr" ] || continue; \
		for root in "$(OVERLAY_INC_MAIN)" "$(OVERLAY_INC_ALT)"; do \
			out="$${root}/$${hdr}"; mkdir -p "$${out%/*}"; \
			{ echo '#pragma once'; IFS=','; for inc in $$incs; do [ -n "$$inc" ] && echo "#include <$$inc>"; done; } > "$$out"; \
			echo "[*] shim: $$out <= $$incs"; \
		done; \
	done

# Clean removes build artifacts (out/) but leaves overlay intact so the
# orchestrator can still pick up headers/libs generated by prior builds.
clean:
	@echo "[*] Cleaning build artifacts (keeping overlay)..."
	rm -rf $(OUT_DIR)
	@echo "[✔] Overlay preserved at $(OVERLAY_DIR)"

# Distclean removes everything produced by this app, including its overlay.
# After this, top-level orchestration must rebuild the app to recreate shims.
distclean:
	@echo "[*] Full cleanup: removing out/ and overlay..."
	rm -rf $(OUT_DIR) $(OVERLAY_DIR)
	@echo "[✔] Everything removed for $(APP)"

# Helper to inspect configuration when debugging CI/env issues.
print-vars:
	@echo BASE_SYSROOT=$(BASE_SYSROOT)
	@echo LLVM_PREFIX=$(LLVM_PREFIX)
	@echo CLANG=$(CLANG)
	@echo AR=$(AR)
	@echo RANLIB=$(RANLIB)
	@echo WASM_OPT=$(WASM_OPT)
	@echo WASMTIME=$(WASMTIME)
	@echo WANT_AOT=$(WANT_AOT)
	@echo SHIM_FORWARDERS=$(SHIM_FORWARDERS)
