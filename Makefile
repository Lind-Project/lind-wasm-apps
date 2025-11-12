# -*- makefile -*-
# lind-wasm-apps unified build (hardened, with lmbench build wrapper)

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# -------- Paths ---------------------------------------------------------------
LIND_WASM_ROOT ?= $(HOME)/lind-wasm
BASE_SYSROOT   ?= $(LIND_WASM_ROOT)/src/glibc/sysroot

APPS_ROOT      := $(CURDIR)
APPS_BUILD     := $(APPS_ROOT)/build
APPS_OVERLAY   := $(APPS_BUILD)/sysroot_overlay
MERGED_SYSROOT := $(APPS_BUILD)/sysroot_merged
APPS_BIN_DIR   := $(APPS_BUILD)/bin
APPS_LIB_DIR   := $(APPS_BUILD)/lib

TOOL_ENV       := $(APPS_BUILD)/.toolchain.env
JOBS ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)

# -------- Phonies -------------------------------------------------------------
.PHONY: all preflight dirs print-config libtirpc merge-sysroot stubs lmbench clean clean-all

all: preflight libtirpc merge-sysroot stubs lmbench

print-config:
	@echo "LIND_WASM_ROOT=$(LIND_WASM_ROOT)"
	@echo "BASE_SYSROOT=$(BASE_SYSROOT)"
	@echo "APPS_OVERLAY=$(APPS_OVERLAY)"
	@echo "MERGED_SYSROOT=$(MERGED_SYSROOT)"
	@echo "APPS_BIN_DIR=$(APPS_BIN_DIR)"
	@echo "APPS_LIB_DIR=$(APPS_LIB_DIR)"
	@if [[ -r '$(TOOL_ENV)' ]]; then . '$(TOOL_ENV)'; \
	  echo "CLANG=$$CLANG"; echo "AR=$$AR"; echo "RANLIB=$$RANLIB"; fi

dirs:
	mkdir -p \
	  '$(APPS_OVERLAY)/usr/include' \
	  '$(APPS_OVERLAY)/usr/lib/wasm32-wasi' \
	  '$(APPS_OVERLAY)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/include' \
	  '$(MERGED_SYSROOT)/include/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/lib/wasm32-wasi' \
	  '$(MERGED_SYSROOT)/usr/lib/wasm32-wasi' \
	  '$(APPS_BIN_DIR)/x86_64-linux-gnu' \
	  '$(APPS_LIB_DIR)'

preflight: dirs
	@echo "[*] preflight checks…"
	[ -r '$(BASE_SYSROOT)/include/wasm32-wasi/stdio.h' ] || { echo "ERROR: sysroot headers missing at $(BASE_SYSROOT)"; exit 1; }
	{
	  set -euo pipefail
	  CLANG_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang" \
	    "$$(command -v clang-18 || true)" \
	    "$$(command -v clang || true)" \
	  )
	  AR_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ar" \
	    "$$(command -v llvm-ar || true)" \
	    "$$(command -v ar || true)" \
	  )
	  RANLIB_CAND=( \
	    "$(LIND_WASM_ROOT)/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ranlib" \
	    "$$(command -v llvm-ranlib || true)" \
	    "$$(command -v ranlib || true)" \
	  )
	  pick() { for x in "$$@"; do [[ -x "$$x" ]] && { echo "$$x"; return; }; done; echo ""; }
	  CLANG="$$(pick "$${CLANG_CAND[@]}")"
	  AR="$$(pick   "$${AR_CAND[@]}")"
	  RANLIB="$$(pick "$${RANLIB_CAND[@]}")"
	  [[ -x "$$CLANG" ]]  || { echo "ERROR: clang not found (tried: $${CLANG_CAND[*]})"; exit 1; }
	  [[ -x "$$AR"    ]]  || { echo "ERROR: llvm-ar/ar not found (tried: $${AR_CAND[*]})"; exit 1; }
	  [[ -x "$$RANLIB" ]] || { echo "ERROR: llvm-ranlib/ranlib not found (tried: $${RANLIB_CAND[*]})"; exit 1; }
	  {
	    echo "export CLANG='$$CLANG'"
	    echo "export AR='$$AR'"
	    echo "export RANLIB='$$RANLIB'"
	  } > '$(TOOL_ENV)'
	  echo "[*] preflight OK"
	  "$$CLANG" --version | head -n1
	}

# ---------------- libtirpc (GSS off) ------------------------------------------
libtirpc: preflight
	. '$(TOOL_ENV)'
	cd '$(APPS_ROOT)/libtirpc'
	if [[ ! -f configure || ! -f Makefile.in ]]; then
	  command -v autoreconf >/dev/null || { echo "ERROR: 'autoreconf' not found (install autoconf automake libtool)"; exit 1; }
	  echo "[libtirpc] autoreconf -fvi"
	  autoreconf -fvi
	fi
	PKG_CONFIG=/bin/false \
	CC="$$CLANG --target=wasm32-unknown-wasi --sysroot=$(BASE_SYSROOT)" \
	AR="$$AR" RANLIB="$$RANLIB" \
	CFLAGS="--sysroot=$(BASE_SYSROOT) -O2 -g" \
	CPPFLAGS="--sysroot=$(BASE_SYSROOT)" \
	LDFLAGS="--sysroot=$(BASE_SYSROOT)" \
	ac_cv_header_gssapi_gssapi_h=no ac_cv_header_gssrpc_auth_gssapi_h=no \
	ac_cv_lib_gssapi_krb5_gss_init_sec_context=no \
	./configure --host=wasm32-unknown-wasi \
	            --enable-static --disable-shared \
	            --disable-gssapi --without-gssapi \
	            --without-krb5 --without-gssapi_krb5
	$(MAKE) -j'$(JOBS)'
	mkdir -p '$(APPS_OVERLAY)/usr/include/tirpc'
	if [[ -d '$(APPS_ROOT)/libtirpc/tirpc' ]]; then \
	  rsync -a '$(APPS_ROOT)/libtirpc/tirpc/' '$(APPS_OVERLAY)/usr/include/tirpc/'; \
	elif [[ -d '$(APPS_ROOT)/libtirpc/include/tirpc' ]]; then \
	  rsync -a '$(APPS_ROOT)/libtirpc/include/tirpc/' '$(APPS_OVERLAY)/usr/include/tirpc/'; \
	else \
	  echo "[libtirpc] WARNING: no tirpc headers found to stage"; \
	fi
	LIB_A="$$(find '$(APPS_ROOT)/libtirpc' -path '*/.libs/libtirpc.a' -print -quit)"
	[[ -f "$$LIB_A" ]] || { echo "[libtirpc] ERROR: libtirpc.a not built"; exit 1; }
	install -m 0644 "$$LIB_A" '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/libtirpc.a'
	install -m 0644 "$$LIB_A" '$(APPS_OVERLAY)/lib/wasm32-wasi/libtirpc.a'
	@echo "[libtirpc] staged: $$LIB_A → overlay (usr/lib & lib)"

# ---------------- Merge sysroot + overlay -------------------------------------
merge-sysroot: libtirpc
	@echo "[merge] refreshing merged sysroot"
	rsync -a --delete '$(BASE_SYSROOT)/' '$(MERGED_SYSROOT)/'
	mkdir -p '$(MERGED_SYSROOT)/include/tirpc' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc'
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/include/tirpc/' '$(MERGED_SYSROOT)/include/wasm32-wasi/tirpc/' || true
	rsync -a '$(APPS_OVERLAY)/usr/lib/wasm32-wasi/' '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true
	rsync -a '$(APPS_OVERLAY)/lib/wasm32-wasi/'     '$(MERGED_SYSROOT)/lib/wasm32-wasi/' || true

# ---------------- Stubs (libm + WASI sched_*) ---------------------------------
stubs: merge-sysroot
	. '$(TOOL_ENV)'
	if [[ ! -f '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' ]]; then
	  echo "[stubs] creating stub libm.a"
	  printf 'void __libm_stub(void){}' > '$(APPS_BUILD)/.libm.c'
	  "$$CLANG" --target=wasm32-unknown-wasi --sysroot='$(MERGED_SYSROOT)' -c '$(APPS_BUILD)/.libm.c' -o '$(APPS_BUILD)/.libm.o'
	  "$$AR" rcs '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' '$(APPS_BUILD)/.libm.o'
	  "$$RANLIB" '$(MERGED_SYSROOT)/lib/wasm32-wasi/libm.a' || true
	fi
	cat > '$(APPS_BUILD)/wasi_compat_stubs.c' <<-'EOF'
		#include <errno.h>
		#include <sched.h>
		int sched_get_priority_max(int policy) { (void)policy; errno = ENOTSUP; return -1; }
		int sched_setscheduler(pid_t pid, int policy, const struct sched_param *param) {
		  (void)pid; (void)policy; (void)param; errno = ENOTSUP; return -1;
		}
	EOF
	"$$CLANG" --target=wasm32-unknown-wasi --sysroot='$(MERGED_SYSROOT)' -c \
	  '$(APPS_BUILD)/wasi_compat_stubs.c' -o '$(APPS_BUILD)/wasi_compat_stubs.o'
	"$$AR" rcs '$(APPS_LIB_DIR)/liblmb_stubs.a' '$(APPS_BUILD)/wasi_compat_stubs.o'
	"$$RANLIB" '$(APPS_LIB_DIR)/liblmb_stubs.a' || true

# ---------------- lmbench (with safe wrappers) --------------------------------
lmbench: stubs
	. '$(TOOL_ENV)'
	mkdir -p '$(APPS_ROOT)/lmbench/src/scripts'

	# ---- scripts/compiler (POSIX /bin/sh; prints one-line CC command) ----
	cat > '$(APPS_ROOT)/lmbench/src/scripts/compiler' <<-'EOF'
		#!/bin/sh
		set -e
		export LC_ALL=C LANG=C
		here=$(cd "$(dirname "$0")" && pwd)
		apps_root=$(cd "$here/../.." && pwd)
		merged="$apps_root/build/sysroot_merged"
		# Load toolchain exported by preflight
		if [ -r "$apps_root/build/.toolchain.env" ]; then
		  . "$apps_root/build/.toolchain.env"
		fi
		: "${CLANG:?missing CLANG from preflight}"
		# Emit ONE line used by Make as the compiler command
		printf "%s " "$CLANG"
		printf -- "--target=wasm32-unknown-wasi --sysroot=%s -O2 -g " "$merged"
		printf -- "-I%s/include -I%s/include/wasm32-wasi -I%s/include/tirpc " "$merged" "$merged" "$merged"
		printf -- "-L%s/lib/wasm32-wasi -L%s/usr/lib/wasm32-wasi -L%s/build/lib -llmb_stubs\n" "$merged" "$merged" "$apps_root"
	EOF
	chmod +x '$(APPS_ROOT)/lmbench/src/scripts/compiler'

	# ---- scripts/build (POSIX /bin/sh; tolerant of empty/noise invocations) ----
	cat > '$(APPS_ROOT)/lmbench/src/scripts/build' <<-'EOF'
		#!/bin/sh
		set -e
		# Case 1: used as shell -> "build -c 'cmd...'"
		if [ "x${1-}" = "x-c" ]; then
		  shift
		  [ -n "${1-}" ] || exit 0
		  exec /bin/sh -c "$1"
		fi
		# Case 2: argv execution; drop leading noise tokens Make may pass
		while [ -n "${1-}" ]; do
		  case "$1" in
		    all|LANG|XLANG) shift ;;
		    *=*)            shift ;;
		    -c)             shift; [ -n "${1-}" ] || exit 0; exec /bin/sh -c "$1" ;;
		    *)              break ;;
		  esac
		done
		# If nothing left to run, succeed quietly
		[ -n "${1-}" ] || exit 0
		exec "$@"
	EOF
	chmod +x '$(APPS_ROOT)/lmbench/src/scripts/build'

	# Tidy upstream Makefile quirks:
	sed -i 's/-Wl,--as-needed//g' '$(APPS_ROOT)/lmbench/src/Makefile' || true
	sed -i -E 's#[[:space:]]\.\./bin/[^[:space:]]+/getopt\.o##g' '$(APPS_ROOT)/lmbench/src/Makefile' || true
	sed -i 's#\.\./scripts/build#\.\./scripts/build#g' '$(APPS_ROOT)/lmbench/src/Makefile' || true

	# Build the common archive first (serial, clearer failures)
	if ! $(MAKE) -C '$(APPS_ROOT)/lmbench/src' -j1 V=1 \
	    CC="`$(APPS_ROOT)/lmbench/src/scripts/compiler`" CFLAGS="" LDFLAGS="" lib 2>/dev/null; then \
	  if ! $(MAKE) -C '$(APPS_ROOT)/lmbench/src' -j1 V=1 \
	    CC="`$(APPS_ROOT)/lmbench/src/scripts/compiler`" CFLAGS="" LDFLAGS="" library 2>/dev/null; then \
	    $(MAKE) -C '$(APPS_ROOT)/lmbench/src' -j1 V=1 \
	      CC="`$(APPS_ROOT)/lmbench/src/scripts/compiler`" CFLAGS="" LDFLAGS=""; \
	  fi; \
	fi

	# Then build the rest
	$(MAKE) -C '$(APPS_ROOT)/lmbench/src' -j'$(JOBS)' V=1 \
	  CC="`$(APPS_ROOT)/lmbench/src/scripts/compiler`" \
	  CFLAGS="" LDFLAGS=""

clean:
	$(MAKE) -C '$(APPS_ROOT)/lmbench/src' clean || true
	-rm -f '$(APPS_BUILD)/.libm.c' '$(APPS_BUILD)/.libm.o' \
	       '$(APPS_BUILD)/wasi_compat_stubs.c' '$(APPS_BUILD)/wasi_compat_stubs.o' \
	       '$(APPS_LIB_DIR)/liblmb_stubs.a'

clean-all: clean
	-rm -rf '$(APPS_OVERLAY)' '$(MERGED_SYSROOT)' '$(APPS_BIN_DIR)' '$(APPS_LIB_DIR)' '$(TOOL_ENV)'
	$(MAKE) -C '$(APPS_ROOT)/libtirpc' distclean || true

