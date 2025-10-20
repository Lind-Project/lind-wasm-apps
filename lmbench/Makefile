# lmbench — per-app sandbox build
# Contract:
#   - make all        -> build overlay + compile .wasm + .cwasm
#   - make clean      -> remove intermediates (keep overlay)
#   - make distclean  -> remove everything incl. overlay

SHELL := /bin/bash

# --- Paths (override as needed) ---
APP              ?= lmbench
SRC_DIR          ?= src
OUT_DIR          ?= out
OVERLAY_DIR      ?= sysroot_overlay

# Overlay include/lib roots (support usr/ and bare include/)
OVERLAY_INC_MAIN := $(OVERLAY_DIR)/usr/include
OVERLAY_INC_ALT  := $(OVERLAY_DIR)/include
OVERLAY_LIB      := $(OVERLAY_DIR)/usr/lib

# --- Base sysroot (your glibc-built sysroot) ---
BASE_SYSROOT     ?= ../../src/glibc/sysroot

# --- Toolchain roots (override these, not the leaf paths) ---
LLVM_PREFIX      ?= /home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04
BINARYEN_PREFIX  ?= /home/lind/lind-wasm/tools/binaryen
WASMTIME_DEFAULT := ../../src/wasmtime/target/release/wasmtime

# Tools (may be overridden by env); we'll normalize them below
CLANG    ?= $(LLVM_PREFIX)/bin/clang
WASM_OPT ?= $(BINARYEN_PREFIX)/bin/wasm-opt
WASMTIME ?= $(if $(wildcard $(WASMTIME_DEFAULT)),$(WASMTIME_DEFAULT),$(shell command -v wasmtime 2>/dev/null || echo /bin/false))
WANT_AOT ?= 1

# Archive tools (use LLVM's to match clang)
AR      ?= $(LLVM_PREFIX)/bin/llvm-ar
RANLIB  ?= $(LLVM_PREFIX)/bin/llvm-ranlib

# --- Tool path normalization (fix common "directory instead of binary" overrides) ---
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

TARGET := wasm32-unknown-wasi

# Extra flags injectable from CLI
CFLAGS_EXTRA  ?=
LDFLAGS_EXTRA ?=

COMMON_CFLAGS := -std=gnu89 --target=$(TARGET) -g -O2 \
                 --sysroot=$(BASE_SYSROOT) \
                 -isystem $(BASE_SYSROOT)/include/wasm32-wasi \
                 -isystem $(BASE_SYSROOT)/include \
                 -isystem $(OVERLAY_INC_MAIN) \
                 -isystem $(OVERLAY_INC_MAIN)/wasm32-wasi \
                 -isystem $(OVERLAY_INC_ALT) \
                 -isystem $(OVERLAY_INC_ALT)/wasm32-wasi \
                 $(CFLAGS_EXTRA)

COMMON_LDFLAGS := -L$(BASE_SYSROOT)/lib/wasm32-wasi \
                  -L$(OVERLAY_LIB) \
                  -Wl,--import-memory,--export-memory,--max-memory=67108864 \
                  -Wl,--export=__stack_pointer,--export=__stack_low \
                  $(LDFLAGS_EXTRA)

# --- Source discovery ---
EXCLUDE_SRCS := getopt.c lat_usleep.c lib_*.c
SRC   := $(filter-out $(EXCLUDE_SRCS),$(notdir $(wildcard $(SRC_DIR)/*.c)))
WASM  := $(patsubst %.c,$(OUT_DIR)/%.wasm,$(SRC))
CWASM := $(patsubst %.wasm,%.cwasm,$(WASM))

# Support code that provides benchmp, bandwidth, mygetopt, etc.
LIB_SRCS := $(wildcard $(SRC_DIR)/lib_*.c) $(SRC_DIR)/getopt.c
LIB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(OUT_DIR)/%.o,$(LIB_SRCS))
LIB_A    := $(OUT_DIR)/liblmbench.a

# --- Shim forwarders list ---
# Format: header=dep1,dep2,...
# Add new entries here as you discover missing headers.
SHIM_FORWARDERS := \
  rpc/rpc.h=rpc/clnt.h,rpc/svc.h \
  rpc/clnt.h= \
  rpc/svc.h= \
  rpc/types.h= \
  netconfig.h=rpc/netconfig.h \
  netdb.h=arpa/inet.h \
  resolv/resolv.h=arpa/nameser.h,netinet/in.h

.PHONY: all build clean distclean overlay-check overlay-shims print-vars

# ---------------------------------------------------------------
all: build

build: overlay-check overlay-shims $(OUT_DIR) $(LIB_A) $(CWASM)
	@echo "[✔] Build complete: $(OUT_DIR)"

$(OUT_DIR):
	mkdir -p $@

# Build support objs and archive into static lib
$(OUT_DIR)/%.o: $(SRC_DIR)/%.c | $(OUT_DIR)
	$(CLANG) $(COMMON_CFLAGS) -c $< -o $@

$(LIB_A): $(LIB_OBJS)
	$(AR) rcs $@ $(LIB_OBJS)
	$(RANLIB) $@

# Compile each test .c → .wasm, link with liblmbench
$(OUT_DIR)/%.wasm: $(SRC_DIR)/%.c $(LIB_A)
	@echo "[*] Compiling $< → $@"
	$(CLANG) $(COMMON_CFLAGS) $< -o $@ $(COMMON_LDFLAGS) $(LIB_A) -lc

# Optimize and (optionally) AOT-compile to .cwasm
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

# ---------------------------------------------------------------
# Validate tool/sysroot, ensure overlay roots exist
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

# Generate forwarder headers from SHIM_FORWARDERS into both overlay include roots
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

# ---------------------------------------------------------------
clean:
	@echo "[*] Cleaning build artifacts (keeping overlay)..."
	rm -rf $(OUT_DIR)
	@echo "[✔] Overlay preserved at $(OVERLAY_DIR)"

distclean:
	@echo "[*] Full cleanup: removing out/ and overlay..."
	rm -rf $(OUT_DIR) $(OVERLAY_DIR)
	@echo "[✔] Everything removed for $(APP)"

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
