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
MERGED_SYSROOT="${APPS_MERGED:-$APPS_ROOT/build/sysroot_merged}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# Output location
GIT_OUT_DIR="$APPS_ROOT/build/bin/git/wasm32-wasi"
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

CFLAGS_WASM="-O2 -g -pthread -matomics -mbulk-memory \
  -I$MERGED_SYSROOT/include \
  -I$MERGED_SYSROOT/include/wasm32-wasi"

LDFLAGS_WASM="-Wl,--import-memory,--export-memory,--max-memory=67108864 \
  -Wl,--export=__stack_pointer,--export=__stack_low,--shared-memory \
  -L$MERGED_SYSROOT/lib/wasm32-wasi \
  -L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

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
# 2. Build git with WASM toolchain
###############################################################################

echo "[git] building git with wasm32-wasi toolchain..."

# Git's Makefile accepts all configuration via variables — no autoconf needed.
# We disable features that require libraries or runtimes unavailable in WASI.
make -j"$JOBS" \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
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

cp git "$GIT_OUT_DIR/git.wasm"
echo "[git] staged: $GIT_OUT_DIR/git.wasm"

###############################################################################
# 4. wasm-opt (best-effort)
###############################################################################

GIT_WASM="$GIT_OUT_DIR/git.wasm"

if [[ -x "$WASM_OPT" ]]; then
  echo "[git] running wasm-opt (asyncify + optimization)..."
  OPT_WASM="$GIT_OUT_DIR/git.opt.wasm"
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
    "$GIT_WASM" -o "$OPT_WASM"
  GIT_WASM="$OPT_WASM"
else
  echo "[git] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
fi

###############################################################################
# 5. cwasm generation (best-effort)
###############################################################################

if [[ -x "$LIND_BOOT" ]]; then
  echo "[git] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$GIT_WASM"; then
    # Rename git.opt.cwasm -> git.cwasm (drop .opt)
    OPT_CWASM="${GIT_WASM%.wasm}.cwasm"
    CLEAN_CWASM="${OPT_CWASM/.opt/}"
    if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
      mv "$OPT_CWASM" "$CLEAN_CWASM"
    fi
  else
    echo "[git] WARNING: lind-boot --precompile failed; skipping cwasm generation."
  fi
else
  echo "[git] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

popd >/dev/null

echo
echo "[git] build complete. Outputs under:"
echo "  $GIT_OUT_DIR"
ls -lh "$GIT_OUT_DIR" || true
