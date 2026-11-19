#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CPython WASI build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Build a native host python (needed for cross-compilation)
#   2. Cross-compile CPython for wasm32-wasi
#   3. Optimize with wasm-opt (asyncify)
#   4. Precompile with lind-boot
#   5. If LIND_DYLINK=1, also build shared libpython and a PIE python binary
#
# Supports both Static (default) and Dynamic (LIND_DYLINK=1) builds.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_BUILD="$APPS_ROOT/build"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

SYSROOT="${SYSROOT:-$APPS_BUILD/sysroot_merged}"
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
ADD_EXPORT_TOOL="${ADD_EXPORT_TOOL:-$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"

CLANG="/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

# Output location
PYTHON_OUT_DIR="$APPS_BUILD/cpython"
BUILD_WASM="$SCRIPT_DIR/build-wasm"

# Sanity
if [[ ! -d "$SYSROOT" ]]; then
  echo "[cpython] ERROR: merged sysroot '$SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$PYTHON_OUT_DIR"

echo "[cpython] using CLANG       = $CLANG"
echo "[cpython] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[cpython] merged sysroot    = $SYSROOT"
echo "[cpython] output dir        = $PYTHON_OUT_DIR"
echo "[cpython] LIND_DYLINK       = $LIND_DYLINK"
echo

mkdir -p "$BUILD_WASM"
pushd "$BUILD_WASM" >/dev/null

  # Build module libraries
  
  build_wasm_shared_lib() {
  local STATIC_LIB="$1"

  # Ensure an argument was passed
  if [[ -z "$STATIC_LIB" ]]; then
    echo "ERROR: Usage: build_wasm_shared_lib <path_to_static_lib.a>" >&2
    return 1
  fi

  # Extract the directory path and the base name (removing the .a extension)
  local LIB_DIR
  LIB_DIR=$(dirname "$STATIC_LIB")

  local BASENAME
  BASENAME=$(basename "$STATIC_LIB" .a)

  # Construct the dynamic paths
  local DYNAMIC_LIB_WASM="$LIB_DIR/$BASENAME.wasm"
  local DYNAMIC_LIB_OPT="$LIB_DIR/$BASENAME.opt.wasm"
  local DYNAMIC_LIB_OPT_CWASM="$LIB_DIR/$BASENAME.opt.cwasm"
  local DYNAMIC_STAGED_LIB="$PYTHON_OUT_DIR/lib/$BASENAME.so"

  echo "[$BASENAME] Starting build for $STATIC_LIB..."

  # Ensure the output directory exists
  mkdir -p "$(dirname "$DYNAMIC_STAGED_LIB")" "$PYTHON_OUT_DIR/usr/local/bin"

  # Build shared library
  "$CLANG" \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot "$SYSROOT" \
    -fvisibility=default \
    -Wl,--import-memory \
    -Wl,--shared-memory \
    -Wl,--export-dynamic \
    -Wl,--experimental-pic \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,-shared \
    -Wl,--whole-archive \
    "$STATIC_LIB" \
    -Wl,--no-whole-archive \
    -Wl,--export=__wasm_call_ctors \
    -Wl,--export-if-defined=__wasm_init_tls \
    -Wl,--export=__tls_base \
    "$SYSROOT/lib/wasm32-wasi/lind_utils.o" \
    -g -O0 -o "$DYNAMIC_LIB_WASM" \
    || { echo "[$BASENAME] ERROR: shared library compilation failed" >&2; return 1; }

  if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
    echo "[$BASENAME] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'" >&2
    return 1
  fi

  # Apply relocations and stack pointer exports
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional \
    || { echo "[$BASENAME] ERROR: add-export-tool tls failed" >&2; return 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional \
    || { echo "[$BASENAME] ERROR: add-export-tool global failed" >&2; return 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __stack_pointer global __stack_pointer optional \
    || { echo "[$BASENAME] ERROR: add-export-tool stack pointer failed" >&2; return 1; }

  # Optimize
  "$WASM_OPT" --enable-bulk-memory --enable-threads \
    --epoch-injection --pass-arg=epoch-import \
    --asyncify --pass-arg=asyncify-import-globals \
    -O2 --debuginfo \
    "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" \
    || { echo "[$BASENAME] ERROR: wasm-opt failed on shared library" >&2; return 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
    echo "[$BASENAME] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'" >&2
    return 1
  fi

  # Precompile
  "$LIND_BOOT" --precompile "$DYNAMIC_LIB_OPT" \
    || { echo "[$BASENAME] ERROR: lind-boot --precompile failed" >&2; return 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
    echo "[$BASENAME] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'" >&2
    return 1
  fi

  # Stage
  cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
  echo "[$BASENAME] Successfully staged as $DYNAMIC_STAGED_LIB"
}


build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA2.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA1.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_Hash_BLAKE2.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA3.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_HMAC.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_hacl/libHacl_Hash_MD5.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/_decimal/libmpdec/libmpdec.a"
build_wasm_shared_lib "$BUILD_WASM/Modules/expat/libexpat.a"


popd >/dev/null

echo
echo "[cpython] build complete. Outputs under:"
echo "  $PYTHON_OUT_DIR"
ls -lh "$PYTHON_OUT_DIR" || true
