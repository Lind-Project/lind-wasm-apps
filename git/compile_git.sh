#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Git WASM build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Clean any previous build
#   2. Build git with wasm32-wasi toolchain, disabling unavailable features
#      (curl, iconv, expat, gettext, perl, python, tcl/tk, unix sockets)
#   3. Stage the main git binary to build/bin/git/wasm32-wasi/
#   4. Optimize with wasm-opt (asyncify)
#   5. Precompile with lind-boot
#
# Supports both Static (default) and Dynamic (LIND_DYLINK=1) builds.
#
# Prerequisites:
#   - Run 'make preflight' and 'make merge-sysroot' from lind-wasm-apps root
#   - Or run 'make all' to build everything including dependencies
###############################################################################

# --- basic paths -------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_ROOT="$APPS_ROOT/git"

TOOL_ENV="$APPS_ROOT/build/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck source=/dev/null
  . "$TOOL_ENV"
fi

if [[ -z "${CLANG:-}" ]]; then
  echo "[git] ERROR: CLANG is not set. Run 'make preflight' from lind-wasm-apps root."
  exit 1
fi

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
MERGED_SYSROOT="$APPS_ROOT/build/sysroot_merged"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

LIND_WASM_OPT="${LIND_WASM_OPT:-$LIND_WASM_ROOT/scripts/bin/lind-wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"

# Output location
GIT_OUT_DIR="$APPS_ROOT/build/git/usr/local/bin"
mkdir -p "$GIT_OUT_DIR"

# --- sanity checks -----------------------------------------------------------

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[git] ERROR: merged sysroot '$MERGED_SYSROOT' not found."
  echo "      Run 'make merge-sysroot' (or 'make all') in lind-wasm-apps first."
  exit 1
fi

if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[git] ERROR: base sysroot headers missing at '$BASE_SYSROOT'."
  echo "      Did you run 'make sysroot' in lind-wasm?"
  exit 1
fi

# --- WASM toolchain flags ----------------------------------------------------

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT"

# Using arrays for flags to handle dynamic additions cleanly
CFLAGS_WASM=(
  -O2 -g -pthread -matomics -mbulk-memory
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

# EH-based setjmp/longjmp (default). The legacy asyncify-based path is
# selected by setting LIND_ASYNCIFY_SETJMP=1, matching lind_compile behaviour.
if [[ -z "${LIND_ASYNCIFY_SETJMP:-}" ]]; then
  CFLAGS_WASM+=(-fwasm-exceptions -mllvm -wasm-enable-sjlj)
fi

# ----------------------------------------------------------------------
# Branch Logic: Dynamic vs Static Settings
# ----------------------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[git] Mode: DYNAMIC LINKING (LIND_DYLINK=1)"
  CFLAGS_WASM+=(-fPIC)

  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[git] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  DYLINK_CRT_OBJS=(
    "$MERGED_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[git] ERROR: required dylink CRT object '$obj' not found." >&2
      exit 1
    fi
  done

  LDFLAGS_WASM=(
    "-nostartfiles"
    "-Wl,-pie"
    "-Wl,--import-table"
    "-Wl,--import-memory"
    "-Wl,--export-memory"
    "-Wl,--shared-memory"
    "-Wl,--max-memory=67108864"
    "-Wl,--allow-undefined"
    "-Wl,--unresolved-symbols=import-dynamic"
    "-Wl,--export=__wasm_call_ctors"
    "-Wl,--export-if-defined=__wasm_init_tls"
    "-Wl,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
    "${DYLINK_CRT_OBJS[@]}"
  )
else
  echo "[git] Mode: STATIC LINKING (LIND_DYLINK=0 or unset)"
  
  LDFLAGS_WASM=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864"
    "-Wl,--export=__stack_pointer,--export=__stack_low,--export=__tls_base,--shared-memory"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
fi

echo "[git] using CLANG       = $CLANG"
echo "[git] using AR          = $AR"
echo "[git] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[git] merged sysroot    = $MERGED_SYSROOT"
echo "[git] output dir        = $GIT_OUT_DIR"
echo

pushd "$GIT_ROOT" >/dev/null

###############################################################################
# 1. Clean any previous build
###############################################################################

echo "[git] cleaning any previous build..."
make distclean >/dev/null 2>&1 || true

###############################################################################
# 1.5. Generate config.mak to override Linux-specific auto-detection
###############################################################################

# config.mak.uname detects the build HOST (Linux) and enables features like
# HAVE_SYSINFO, HAVE_PLATFORM_PROCINFO, HAVE_SYNC_FILE_RANGE, getrandom, etc.
# These don't exist in WASI. config.mak is included after config.mak.uname
# and overrides those settings.

echo "[git] generating config.mak for WASI cross-compilation..."
cat > config.mak << 'CONFIGMAK'
# Generated by compile_git.sh — WASI cross-compilation overrides.
# Undo Linux-specific settings from config.mak.uname that break WASI builds.

# sysinfo(2) is Linux-specific (used in builtin/gc.c)
HAVE_SYSINFO =

# Linux procinfo uses /proc/self/exe — use the generic stub instead
HAVE_PLATFORM_PROCINFO =
PROCFS_EXECUTABLE_PATH =

# sync_file_range(2) is Linux-specific
HAVE_SYNC_FILE_RANGE =

# getrandom(2) may not be available in WASI; fall back to openssl
CSPRNG_METHOD = openssl

# Fuzz programs use --allow-multiple-definition which wasm-ld doesn't support
LINK_FUZZ_PROGRAMS =

# WASI stubs for missing POSIX functions (getpgid, etc.)
COMPAT_OBJS += compat/wasi-stubs.o
CONFIGMAK

###############################################################################
# 1.6. Create WASI compatibility stubs
###############################################################################

echo "[git] creating WASI compatibility stubs..."
mkdir -p compat

cat > compat/wasi-stubs.c << 'STUBS'
/*
 * WASI stubs for POSIX functions missing from the wasm32-wasi sysroot.
 * Used when cross-compiling git for lind-wasm.
 */

#include <sys/types.h>
#include <unistd.h>
#include <errno.h>

/*
 * getpgid(2) — return process group ID.
 * Used by progress.c to detect foreground process group.
 * In WASI's single-process model the process group is just the process itself.
 */
pid_t getpgid(pid_t pid)
{
    (void)pid;
    return getpid();
}
STUBS

###############################################################################
# 2. Build git with WASM toolchain
###############################################################################

echo "[git] building git with wasm32-wasi toolchain..."

# Git's Makefile accepts all configuration via variables — no autoconf needed.
# We disable features that require libraries or runtimes unavailable in WASI.
# config.mak (generated above) handles Linux-specific overrides.
# Injecting our constructed CFLAGS and LDFLAGS arrays here.
make -j"$JOBS" \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  LDFLAGS="${LDFLAGS_WASM[*]}" \
  NO_CURL=1 \
  NO_ICONV=1 \
  NO_EXPAT=1 \
  NO_GETTEXT=1 \
  NO_PERL=1 \
  NO_PYTHON=1 \
  NO_TCLTK=1 \
  NO_UNIX_SOCKETS=1 \
  NO_INSTALL_HARDLINKS=1 \
  NEEDS_CRYPTO_WITH_SSL=1 \
  prefix=/usr/local

###############################################################################
# 3. Stage the main git binary
###############################################################################

if [[ ! -f git ]]; then
  echo "[git] ERROR: git binary was not produced."
  exit 1
fi

GIT_WASM="$SCRIPT_DIR/git.wasm"
GIT_OPT_WASM="$SCRIPT_DIR/git.opt.wasm"

cp git "$GIT_WASM"

###############################################################################
# 4. wasm-opt & exports
###############################################################################

if [[ -x "$LIND_WASM_OPT" ]]; then
  echo "[git] running lind-wasm-opt..."
  if [[ "$LIND_DYLINK" == "1" ]]; then
    # --fpcast-emu: dylink mains must match the fpcast-built libc.cwasm table
    # convention or cross-module indirect calls trap at exit.
    "$LIND_WASM_OPT" --target=main --fpcast-emu \
      "$GIT_WASM" -o "$GIT_OPT_WASM"
  else
    "$LIND_WASM_OPT" --static \
      "$GIT_WASM" -o "$GIT_OPT_WASM"
  fi
else
  echo "[git] NOTE: lind-wasm-opt not found at '$LIND_WASM_OPT'; skipping optimization. Exiting.."
  exit 1
fi

if [[ ! -f "$GIT_OPT_WASM" ]]; then
  echo "[git] ERROR: Failed to generate $GIT_OPT_WASM; Exiting.."
  exit 1
fi

# Add dylink exports if dynamic linking is enabled
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[git] adding dylink exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$GIT_OPT_WASM" "$GIT_OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$GIT_OPT_WASM" "$GIT_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$GIT_OPT_WASM" "$GIT_OPT_WASM" __stack_pointer global __stack_pointer
fi

###############################################################################
# 5. cwasm generation (best-effort)
###############################################################################

if [[ -x "$LIND_BOOT" ]]; then
  echo "[git] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$GIT_OPT_WASM"; then
    
    GIT_OPT_CWASM="$SCRIPT_DIR/git.opt.cwasm"

    if [[ -f "$GIT_OPT_CWASM" ]]; then
      cp "$GIT_OPT_CWASM" "$GIT_OUT_DIR/git"
      echo "[git] git staged as $GIT_OUT_DIR/git "
    else
      echo "[git] ERROR: No .cwasm binary generated and no binaries copied to the build folder. Exiting .."
      exit 1
    fi
  else
    echo "[git] ERROR: lind-boot --precompile failed; skipping cwasm generation."
    echo "[git] ERROR: No binaries copied to the build folder. Exiting.."
    exit 1
  fi
else
  echo "[git] ERROR: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  echo "[git] ERROR: No binaries copied to the build folder. Exiting.."
  exit 1
fi

popd >/dev/null

echo
echo "[git] build complete. Outputs under:"
echo "  $GIT_OUT_DIR"
ls -lh "$GIT_OUT_DIR" || true
