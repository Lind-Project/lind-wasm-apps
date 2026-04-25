# -*- makefile -*-
# lind-wasm-apps unified build (hardened, with lmbench build wrapper)

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# -------- Build mode ----------------------------------------------------------
# Set LIND_DYLINK=1 for dynamic/PIE builds, 0 for static.
# Exported so all compile scripts inherit it.
LIND_DYLINK    ?= 1
export LIND_DYLINK

# -------- Paths ---------------------------------------------------------------
LIND_WASM_ROOT ?= $(HOME)/lind-wasm
BASE_SYSROOT   ?= $(LIND_WASM_ROOT)/src/glibc/sysroot
LLVM_BIN_DIR   ?= $(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin

APPS_ROOT      := $(CURDIR)
APPS_BUILD     := $(APPS_ROOT)/build
APPS_OVERLAY   := $(APPS_BUILD)/sysroot_overlay
MERGED_SYSROOT := $(APPS_BUILD)/sysroot_merged
APPS_BIN_DIR   := $(APPS_BUILD)/bin
APPS_LIB_DIR   := $(APPS_BUILD)/lib
LIBTIRPC_STAMP := $(APPS_BUILD)/.stamp_libtirpc
GNULIB_STAMP   := $(APPS_BUILD)/.stamp_gnulib
ZLIB_STAMP     := $(APPS_BUILD)/.stamp_zlib
OPENSSL_STAMP  := $(APPS_BUILD)/.stamp_openssl
LIBCXX_STAMP   := $(APPS_BUILD)/.stamp_libcxx
MERGE_BASE_STAMP    := $(APPS_BUILD)/.stamp_merge_base_sysroot
MERGE_TIRPC_STAMP   := $(APPS_BUILD)/.stamp_merge_tirpc
MERGE_GNULIB_STAMP  := $(APPS_BUILD)/.stamp_merge_gnulib
MERGE_ZLIB_STAMP    := $(APPS_BUILD)/.stamp_merge_zlib
MERGE_OPENSSL_STAMP := $(APPS_BUILD)/.stamp_merge_openssl
MERGE_LIBCXX_STAMP  := $(APPS_BUILD)/.stamp_merge_libcxx
MERGE_ALL_STAMP     := $(APPS_BUILD)/.stamp_merge_sysroot

TOOL_ENV       := $(APPS_BUILD)/.toolchain.env
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)

LINDFS_ROOT    := $(LIND_WASM_ROOT)/lindfs

# Keep this list in sync as app-specific expected-binaries manifests come online.
# Usage:
#   make check-build                # runs the full TESTABLE_APPS list
#   make check-build APP=nginx      # runs a single app on demand
#   make check-build APP="nginx grep sed"  # runs multiple apps on demand
TESTABLE_APPS  := bash coreutils curl git grep lmbench sed tinycc cpython
APP            ?= $(TESTABLE_APPS)

# -------- Phonies -------------------------------------------------------------
.PHONY: all preflight dirs print-config check-build libtirpc gnulib zlib openssl libcxx merge-base-sysroot merge-sysroot lmbench bash nginx coreutils cpython git curl grep sed gcc binutils clang postgres tinycc diffutils clean clean-all rebuild-libs rebuild-sysroot install-bash install-nginx install-git install-curl install-grep install-sed install-lmbench install-coreutils install-gcc install-binutils install-clang install-tinycc install-cpython install-postgres install-diffutils install-gnulib install-libtirpc install-openssl install-zlib install-libcxx install

all: preflight libtirpc gnulib merge-sysroot lmbench bash

test:
	@if [[ -z "$(strip $(APP))" ]]; then \
	  echo "ERROR: no apps selected; set APP to one or more of: $(TESTABLE_APPS)"; \
	  exit 1; \
	fi
	@for app in $(APP); do \
	  case " $(TESTABLE_APPS) " in \
	    *" $$app "*) ;; \
	    *) echo "ERROR: unsupported test app '$$app'; supported apps: $(TESTABLE_APPS)"; exit 1 ;; \
	  esac; \
	  if [[ -x '$(APPS_ROOT)/'"$$app"'/run_tests.sh' ]]; then \
	    '$(APPS_ROOT)/'"$$app"'/run_tests.sh' "$$app"; \
	  else \
	    echo "[SKIP] $$app: missing $(APPS_ROOT)/$$app/run_tests.sh"; \
	  fi; \
	done

check-build:
	@if [[ -z "$(strip $(APP))" ]]; then \
	  echo "ERROR: no apps selected; set APP to one or more of: $(TESTABLE_APPS)"; \
	  exit 1; \
	fi
	@for app in $(APP); do \
	  case " $(TESTABLE_APPS) " in \
	    *" $$app "*) ;; \
	    *) echo "ERROR: unsupported test app '$$app'; supported apps: $(TESTABLE_APPS)"; exit 1 ;; \
	  esac; \
	  
	  '$(APPS_ROOT)/scripts/check-build.sh' "$$app"; \
	done

clean:
	@# Per-app clean scripts (optional — skips apps without clean.sh)
	@for app in $(APP); do \
	  case " $(TESTABLE_APPS) " in \
	    *" $$app "*) ;; \
	    *) continue ;; \
	  esac; \
	  if [[ -x '$(APPS_ROOT)/'"$$app"'/clean.sh' ]]; then \
	    '$(APPS_ROOT)/'"$$app"'/clean.sh' "$$app"; \
	  fi; \
	done
	@# Infrastructure: stamps, sysroot, overlay, toolchain env
	-rm -rf '$(APPS_OVERLAY)' '$(MERGED_SYSROOT)' '$(APPS_BIN_DIR)' '$(APPS_LIB_DIR)' '$(TOOL_ENV)'
	-rm -f '$(LIBTIRPC_STAMP)' '$(GNULIB_STAMP)' '$(ZLIB_STAMP)' '$(OPENSSL_STAMP)' '$(LIBCXX_STAMP)'
	-rm -f '$(MERGE_BASE_STAMP)' '$(MERGE_TIRPC_STAMP)' '$(MERGE_GNULIB_STAMP)' '$(MERGE_ZLIB_STAMP)' '$(MERGE_OPENSSL_STAMP)' '$(MERGE_LIBCXX_STAMP)' '$(MERGE_ALL_STAMP)'

print-config:
	@echo "LIND_WASM_ROOT=$(LIND_WASM_ROOT)"
	@echo "BASE_SYSROOT=$(BASE_SYSROOT)"
	@echo "APPS_OVERLAY=$(APPS_OVERLAY)"
	@echo "MERGED_SYSROOT=$(MERGED_SYSROOT)"
	@echo "APPS_BIN_DIR=$(APPS_BIN_DIR)"
	@echo "APPS_LIB_DIR=$(APPS_LIB_DIR)"
	@if [[ -r '$(TOOL_ENV)' ]]; then . '$(TOOL_ENV)'; \
	  echo "CLANG=$$CLANG"; echo "AR=$$AR"; echo "RANLIB=$$RANLIB"; echo "NM=$$NM"; fi

dirs:
	mkdir -p \
	  '$(APPS_OVERLAY)/usr/include' \
	  '$(APPS_OVERLAY)/usr/lib/wasm32-wasi' \
	  '$(APPS_OVERLAY)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/include' \
	  '$(MERGED_SYSROOT)/include/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/usr/lib/wasm32-wasi' \
	  '$(APPS_BIN_DIR)' \
	  '$(APPS_LIB_DIR)'

#   TODO:
#     Once we have a shared helper in lind-wasm (or a stable
#     container path for the toolchain), we should move this into a small
#     script (e.g. scripts/detect_toolchain.sh) or reuse a common helper
#     so the Makefile itself can stay leaner.
$(TOOL_ENV): | dirs
	@echo "[*] preflight checks…"
	[ -r '$(BASE_SYSROOT)/include/wasm32-wasi/stdio.h' ] || { echo "ERROR: sysroot headers missing at $(BASE_SYSROOT)"; exit 1; }
	{
	  set -euo pipefail
	  CLANG='$(LLVM_BIN_DIR)/clang'
	  AR='$(LLVM_BIN_DIR)/llvm-ar'
	  RANLIB='$(LLVM_BIN_DIR)/llvm-ranlib'
	  NM='$(LLVM_BIN_DIR)/llvm-nm'
	  [[ -x "$$CLANG"  ]] || { echo "ERROR: expected clang at $$CLANG"; exit 1; }
	  [[ -x "$$AR"     ]] || { echo "ERROR: expected llvm-ar at $$AR"; exit 1; }
	  [[ -x "$$RANLIB" ]] || { echo "ERROR: expected llvm-ranlib at $$RANLIB"; exit 1; }
	  [[ -x "$$NM"     ]] || { echo "ERROR: expected llvm-nm at $$NM"; exit 1; }
	  {
	    echo "export CLANG='$$CLANG'"
	    echo "export AR='$$AR'"
	    echo "export RANLIB='$$RANLIB'"
	    echo "export NM='$$NM'"
	  } > '$(TOOL_ENV)'
	  echo "[*] preflight OK"
	  "$$CLANG" --version | head -n1
	}

preflight: $(TOOL_ENV)

# ---------------- libtirpc (via compile_libtirpc.sh) -------------------------
$(LIBTIRPC_STAMP): $(APPS_ROOT)/libtirpc/compile_libtirpc.sh | $(TOOL_ENV)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/libtirpc/compile_libtirpc.sh'
	touch '$@'

libtirpc: $(LIBTIRPC_STAMP)

# ---------------- gnulib (via compile_gnulib.sh) -----------------------------
$(GNULIB_STAMP): $(APPS_ROOT)/gnulib/compile_gnulib.sh | $(TOOL_ENV)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/gnulib/compile_gnulib.sh'
	touch '$@'

gnulib: $(GNULIB_STAMP)

# ---------------- zlib (via compile_zlib.sh) ----------------------------------
$(ZLIB_STAMP): $(APPS_ROOT)/zlib/compile_zlib.sh | $(TOOL_ENV)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/zlib/compile_zlib.sh'
	touch '$@'

zlib: $(ZLIB_STAMP)

# ---------------- openssl (via compile_openssl.sh) ----------------------------
$(OPENSSL_STAMP): $(APPS_ROOT)/openssl/compile_openssl.sh | $(TOOL_ENV)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/openssl/compile_openssl.sh'
	touch '$@'

openssl: $(OPENSSL_STAMP)

# ---------------- libc++ (via compile_libcxx.sh) ------------------------------
$(LIBCXX_STAMP): $(APPS_ROOT)/llvm-project/compile_libcxx.sh | $(TOOL_ENV)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/llvm-project/compile_libcxx.sh'
	touch '$@'

libcxx: $(LIBCXX_STAMP)

# ---------------- Merge sysroot + overlay -------------------------------------
$(MERGE_BASE_STAMP): | $(TOOL_ENV)
	@echo "[merge] refreshing base merged sysroot"
	rsync -a --delete '$(BASE_SYSROOT)/' '$(MERGED_SYSROOT)/'
	touch '$@'

merge-base-sysroot: $(MERGE_BASE_STAMP)


$(MERGE_TIRPC_STAMP): $(MERGE_BASE_STAMP) $(LIBTIRPC_STAMP)
	# libtirpc headers
	mkdir -p '$(MERGED_SYSROOT)/include/tirpc' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc'
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	touch '$@'


$(MERGE_GNULIB_STAMP): $(MERGE_BASE_STAMP) $(GNULIB_STAMP)
	# gnulib headers (placed under include/gnulib/)
	mkdir -p '$(MERGED_SYSROOT)/include/gnulib' '$(MERGED_SYSROOT)/include/wasm32-wasi/gnulib'
	rsync -a '$(APPS_OVERLAY)/usr/include/gnulib/' '$(MERGED_SYSROOT)/include/gnulib/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/gnulib/' '$(MERGED_SYSROOT)/include/wasm32-wasi/gnulib/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	touch '$@'


$(MERGE_ZLIB_STAMP): $(MERGE_BASE_STAMP) $(ZLIB_STAMP)
	# zlib headers
	cp -f '$(APPS_OVERLAY)/usr/include/zlib.h' '$(MERGED_SYSROOT)/include/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zconf.h' '$(MERGED_SYSROOT)/include/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zlib.h' '$(MERGED_SYSROOT)/include/wasm32-wasi/' || true
	cp -f '$(APPS_OVERLAY)/usr/include/zconf.h' '$(MERGED_SYSROOT)/include/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	touch '$@'


$(MERGE_OPENSSL_STAMP): $(MERGE_BASE_STAMP) $(OPENSSL_STAMP)
	# openssl headers
	mkdir -p '$(MERGED_SYSROOT)/include/openssl' '$(MERGED_SYSROOT)/include/wasm32-wasi/openssl'
	rsync -a '$(APPS_OVERLAY)/usr/include/openssl/' '$(MERGED_SYSROOT)/include/openssl/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/openssl/' '$(MERGED_SYSROOT)/include/wasm32-wasi/openssl/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	touch '$@'


$(MERGE_LIBCXX_STAMP): $(MERGE_BASE_STAMP) $(LIBCXX_STAMP)
	# libc++ headers (into include/wasm32-wasi/c++/ so clang's -isystem finds them)
	mkdir -p '$(MERGED_SYSROOT)/include/wasm32-wasi/c++'
	rsync -a '$(APPS_OVERLAY)/usr/include/c++/' '$(MERGED_SYSROOT)/include/wasm32-wasi/c++/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	touch '$@'


$(MERGE_ALL_STAMP): $(MERGE_TIRPC_STAMP) $(MERGE_GNULIB_STAMP) $(MERGE_ZLIB_STAMP) $(MERGE_OPENSSL_STAMP) $(MERGE_LIBCXX_STAMP)
	touch '$@'

merge-sysroot: $(MERGE_ALL_STAMP)

# ---------------- lmbench (via compile_lmbench.sh) ---------------------------
lmbench: $(MERGE_TIRPC_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/lmbench/src/compile_lmbench.sh'

# ---------------- bash (WASM build) -------------------------------------------
# Uses bash/compile_bash.sh to build bash as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and stages artifacts
# under build/bash/bin.
bash: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/bash/compile_bash.sh'

# ---------------- nginx (WASM build) -------------------------------------------
# Uses nginx/compile_nginx.sh to build nginx as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and stages artifacts
# under build/bin/nginx/wasm32-wasi/.
nginx: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/nginx/compile_nginx.sh'

# ---------------- coreutils (WASM build) --------------------------------------
# Uses coreutils/compile_coreutils.sh and requires the merged sysroot,
# stages artifacts under build/coreutils/bin.
coreutils: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/coreutils/compile_coreutils.sh'

# ---------------- git (WASM build) --------------------------------------------
# Uses git/compile_git.sh to build git as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight (zlib + OpenSSL), and
# stages artifacts under build/git.
git: $(MERGE_ZLIB_STAMP) $(MERGE_OPENSSL_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/git/compile_git.sh'

# ---------------- curl (WASM build) -------------------------------------------
# Uses curl/compile_curl.sh to build curl as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight (zlib + OpenSSL), and
# stages artifacts under build/curl.
curl: $(MERGE_ZLIB_STAMP) $(MERGE_OPENSSL_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/curl/compile_curl.sh'

# ---------------- grep (WASM build) -------------------------------------------
# Uses grep/compile_grep.sh to build grep as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and
# stages artifacts under build/grep.
grep: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/grep/compile_grep.sh'

# ---------------- sed (WASM build) --------------------------------------------
# Uses sed/compile_sed.sh to build sed as a wasm32-wasi binary using the
# merged sysroot and toolchain detected by preflight, and
# stages artifacts under build/sed.
sed: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/sed/compile_sed.sh'

# ---------------- gcc (WASM build) --------------------------------------------
# Uses gcc/compile_gcc.sh to cross-compile GCC cc1 as a wasm32-wasi binary.
# Requires libc++ in the merged sysroot (for compiling GCC's C++ source).
# Stages artifacts under build/gcc/usr/local/bin.
gcc: $(MERGE_LIBCXX_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/gcc/compile_gcc.sh'

# ---------------- binutils (WASM build) ----------------------------------------
# Uses binutils/compile_binutils.sh to cross-compile ld and as as wasm32-wasi
# binaries.  Pure C — no libc++ needed.  Stages to build/binutils/usr/local/bin.
binutils: $(MERGE_ZLIB_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/binutils/compile_binutils.sh'

# ---------------- clang (WASM build) -------------------------------------------
# Uses llvm-project/compile_clang.sh to cross-compile clang and lld as
# wasm32-wasi binaries.  Requires libc++ in the merged sysroot (C++ source).
# Stages artifacts under build/clang/usr/local/bin.
clang: $(MERGE_LIBCXX_STAMP)
	. '$(TOOL_ENV)'
	JOBS='$(JOBS)' '$(APPS_ROOT)/llvm-project/compile_clang.sh'

rebuild-libs:
	rm -f '$(LIBTIRPC_STAMP)' '$(GNULIB_STAMP)' '$(ZLIB_STAMP)' '$(OPENSSL_STAMP)' '$(LIBCXX_STAMP)' \
	  '$(MERGE_TIRPC_STAMP)' '$(MERGE_GNULIB_STAMP)' '$(MERGE_ZLIB_STAMP)' '$(MERGE_OPENSSL_STAMP)' '$(MERGE_LIBCXX_STAMP)' '$(MERGE_ALL_STAMP)'

rebuild-sysroot:
	rm -f '$(MERGE_BASE_STAMP)' '$(MERGE_TIRPC_STAMP)' '$(MERGE_GNULIB_STAMP)' '$(MERGE_ZLIB_STAMP)' '$(MERGE_OPENSSL_STAMP)' '$(MERGE_LIBCXX_STAMP)' '$(MERGE_ALL_STAMP)'

# ---------------- cpython (WASM build) ----------------------------------------
# Uses cpython/compile_cpython.sh to cross-compile CPython for wasm32-wasi.
# Supports both static (default) and dynamic (LIND_DYLINK=1) builds.
cpython: $(MERGE_ZLIB_STAMP) $(MERGE_OPENSSL_STAMP)
	'$(APPS_ROOT)/cpython/compile_cpython.sh'

# ---------------- postgres (WASM build) ---------------------------------------
# Uses postgres/compile_postgres.sh to build the PostgreSQL backend as a
# wasm32-wasi binary using the merged sysroot and toolchain detected by
# preflight, and stages artifacts under build/bin/postgres/wasm32-wasi/.
postgres: $(MERGE_BASE_STAMP)
	. '$(TOOL_ENV)'
	'$(APPS_ROOT)/postgres/compile_postgres.sh'

# ---------------- tinycc (WASM build) --------------------------------------
tinycc: merge-sysroot
	'$(APPS_ROOT)/tinycc/compile_tinycc.sh'

# ---------------- diffutils (WASM build) --------------------------------------
# Cross-compiles GNU diffutils (cmp, diff, diff3, sdiff) to wasm32-wasi.
# Stages to build/diffutils/usr/local/bin.
diffutils: $(MERGE_BASE_STAMP)
	'$(APPS_ROOT)/diffutils/compile_diffutils.sh'

install-bash:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' bash

install-nginx:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' nginx

install-git: install-zlib install-openssl
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' git

install-curl: install-zlib install-openssl
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' curl

install-grep:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' grep

install-sed:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' sed

install-lmbench: install-libtirpc
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' lmbench

install-coreutils:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' coreutils

install-gcc: install-libcxx
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' gcc

install-binutils: install-zlib
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' binutils

install-clang: install-libcxx
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' clang

install-tinycc:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' tinycc

install-cpython: install-zlib install-openssl
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' cpython

install-postgres:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' postgres

install-diffutils:
	'$(APPS_ROOT)/scripts/post_install.sh' '$(LINDFS_ROOT)' '$(APPS_BUILD)' diffutils

install-gnulib:
	'$(APPS_ROOT)/scripts/post_install_lib.sh' '$(LINDFS_ROOT)' gnulib

install-libtirpc:
	'$(APPS_ROOT)/scripts/post_install_lib.sh' '$(LINDFS_ROOT)' libtirpc

install-openssl:
	'$(APPS_ROOT)/scripts/post_install_lib.sh' '$(LINDFS_ROOT)' openssl

install-zlib:
	'$(APPS_ROOT)/scripts/post_install_lib.sh' '$(LINDFS_ROOT)' zlib

install-libcxx:
	'$(APPS_ROOT)/scripts/post_install_lib.sh' '$(LINDFS_ROOT)' libcxx

install: install-bash install-nginx install-git install-curl install-grep install-sed install-lmbench install-coreutils install-gcc install-binutils install-clang install-tinycc install-cpython install-postgres install-diffutils install-gnulib install-libtirpc install-openssl install-zlib install-libcxx
