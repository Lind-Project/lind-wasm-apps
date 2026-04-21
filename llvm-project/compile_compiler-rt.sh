#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# compiler-rt WASI build helper for lind-wasm-apps
#
# Cross-compiles LLVM compiler-rt builtins to wasm32-wasi using the toolchain
# detected by the top-level Makefile preflight target. Installs static runtime
# libraries to the sysroot overlay so merge-sysroot can pick them up.
#
# Prerequisites:
#   - Run 'make preflight' first
#   - cmake >= 3.20 must be on PATH
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLVM_SRC="$SCRIPT_DIR"

APPS_BUILD="$APPS_ROOT/build"
APPS_OVERLAY="$APPS_BUILD/sysroot_overlay"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[compiler-rt] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"
: "${NM:?missing NM in $TOOL_ENV}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
CLANGXX="$LLVM_BIN_DIR/clang++"
if [[ ! -x "$CLANGXX" ]]; then
  echo "[compiler-rt] WARN: clang++ not found at '$CLANGXX'; creating symlink to clang"
  ln -sf "$CLANG" "$CLANGXX"
fi

# Sanity checks
if [[ ! -d "$LLVM_SRC/compiler-rt" ]]; then
  echo "[compiler-rt] ERROR: compiler-rt source not found at '$LLVM_SRC/compiler-rt'" >&2
  exit 1
fi

if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[compiler-rt] ERROR: base sysroot headers missing at '$BASE_SYSROOT'" >&2
  exit 1
fi

CMAKE="${CMAKE:-cmake}"
if ! command -v "$CMAKE" &>/dev/null; then
  echo "[compiler-rt] ERROR: cmake not found on PATH" >&2
  exit 1
fi

BUILD_DIR="$APPS_BUILD/compiler-rt-build"
INSTALL_DIR="$APPS_BUILD/compiler-rt-install"

echo "[compiler-rt] using CLANG       = $CLANG"
echo "[compiler-rt] using CLANGXX     = $CLANGXX"
echo "[compiler-rt] using AR          = $AR"
echo "[compiler-rt] using NM          = $NM"
echo "[compiler-rt] using RANLIB      = $RANLIB"
echo "[compiler-rt] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[compiler-rt] base sysroot      = $BASE_SYSROOT"
echo "[compiler-rt] build dir         = $BUILD_DIR"
echo "[compiler-rt] install dir       = $INSTALL_DIR"
echo

mkdir -p "$BUILD_DIR"

# ----------------------------------------------------------------------
# 2) Generate CMake toolchain file for wasm32-wasi cross-compilation
# ----------------------------------------------------------------------
TOOLCHAIN_FILE="$BUILD_DIR/Toolchain-WASI.cmake"
sed -e "s|@CLANG@|$CLANG|g" \
    -e "s|@CLANGXX@|$CLANGXX|g" \
    -e "s|@AR@|$AR|g" \
    -e "s|@NM@|$NM|g" \
    -e "s|@RANLIB@|$RANLIB|g" \
    -e "s|@BASE_SYSROOT@|$BASE_SYSROOT|g" \
    "$SCRIPT_DIR/Toolchain-WASI.cmake.in" > "$TOOLCHAIN_FILE"

echo "[compiler-rt] generated toolchain file: $TOOLCHAIN_FILE"

# ----------------------------------------------------------------------
# 3) Configure with CMake
# ----------------------------------------------------------------------
echo "[compiler-rt] configuring…"

"$CMAKE" -B "$BUILD_DIR" -S "$LLVM_SRC/compiler-rt" \
  -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_C_COMPILER_WORKS=1 \
  -DCMAKE_CXX_COMPILER_WORKS=1 \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF

# ----------------------------------------------------------------------
# 4) Build and install
# ----------------------------------------------------------------------
echo "[compiler-rt] building…"
"$CMAKE" --build "$BUILD_DIR" --target install -j"$JOBS"

# ----------------------------------------------------------------------
# 5) Copy libraries to sysroot overlay
# ----------------------------------------------------------------------
echo "[compiler-rt] installing to sysroot overlay…"

mkdir -p "$APPS_OVERLAY/usr/lib/wasm32-wasi"

find "$INSTALL_DIR" -type f \( -name 'libclang_rt.builtins*.a' -o -name 'libcompiler_rt*.a' \) \
  -exec cp -v {} "$APPS_OVERLAY/usr/lib/wasm32-wasi/" \;

echo
echo "[compiler-rt] build complete. Outputs:"
echo "  libs: $APPS_OVERLAY/usr/lib/wasm32-wasi/"
ls -lh "$APPS_OVERLAY/usr/lib/wasm32-wasi/" | grep -E 'clang_rt|compiler_rt' || true
