#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# libc++ / libc++abi WASI build helper for lind-wasm-apps
#
# Cross-compiles LLVM libc++ and libc++abi to wasm32-wasi using the toolchain
# detected by the top-level Makefile preflight target.  Installs headers and
# static libraries to the sysroot overlay so merge-sysroot can pick them up.
#
# Based on the approach in Lind-Project/lind-wasm PR #976.
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
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/../lind-wasm" && pwd)"
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
  echo "[libcxx] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"
: "${NM:?missing NM in $TOOL_ENV}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
# clang++ is typically a symlink next to clang
CLANGXX="$LLVM_BIN_DIR/clang++"
if [[ ! -x "$CLANGXX" ]]; then
  echo "[libcxx] WARN: clang++ not found at '$CLANGXX'; creating symlink to clang"
  ln -sf "$CLANG" "$CLANGXX"
fi

# Sanity checks
if [[ ! -d "$LLVM_SRC/libcxx" ]]; then
  echo "[libcxx] ERROR: libc++ source not found at '$LLVM_SRC/libcxx'" >&2
  exit 1
fi
if [[ ! -d "$LLVM_SRC/libcxxabi" ]]; then
  echo "[libcxx] ERROR: libc++abi source not found at '$LLVM_SRC/libcxxabi'" >&2
  exit 1
fi
if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[libcxx] ERROR: base sysroot headers missing at '$BASE_SYSROOT'" >&2
  exit 1
fi

CMAKE="${CMAKE:-cmake}"
if ! command -v "$CMAKE" &>/dev/null; then
  echo "[libcxx] ERROR: cmake not found on PATH" >&2
  exit 1
fi

BUILD_DIR="$APPS_BUILD/libcxx-build"
INSTALL_DIR="$APPS_BUILD/libcxx-install"

echo "[libcxx] using CLANG       = $CLANG"
echo "[libcxx] using CLANGXX     = $CLANGXX"
echo "[libcxx] using AR          = $AR"
echo "[libcxx] using NM          = $NM"
echo "[libcxx] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[libcxx] base sysroot      = $BASE_SYSROOT"
echo "[libcxx] build dir         = $BUILD_DIR"
echo "[libcxx] install dir       = $INSTALL_DIR"
echo

# ----------------------------------------------------------------------
# 2) Patch libc++ time_utils.h (reinterpret_cast fix for WASI timespec)
#    See: Lind-Project/lind-wasm PR #976
# ----------------------------------------------------------------------
TIME_UTILS="$LLVM_SRC/libcxx/src/filesystem/time_utils.h"
if [[ -f "$TIME_UTILS" ]]; then
  if grep -q 'reinterpret_cast<long\*>' "$TIME_UTILS"; then
    echo "[libcxx] [patch] time_utils.h already patched; skipping."
  else
    python3 - <<'PY' "$TIME_UTILS"
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text(errors="ignore")

old = "return set_times_checked(&dest.tv_sec, &dest.tv_nsec, tp);"
new = "return set_times_checked(reinterpret_cast<long*>(&dest.tv_sec),\n                         reinterpret_cast<long*>(&dest.tv_nsec),\n                         tp);"

if old in s:
    p.write_text(s.replace(old, new))
    print(f"[libcxx] [patch] added reinterpret_cast fix to {p}")
else:
    print(f"[libcxx] WARN: time_utils.h patch pattern not found in {p}", file=sys.stderr)
PY
  fi
fi

# ----------------------------------------------------------------------
# 3) Generate CMake toolchain file for wasm32-wasi cross-compilation
# ----------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

TOOLCHAIN_FILE="$BUILD_DIR/Toolchain-WASI.cmake"
sed -e "s|@CLANG@|$CLANG|g" \
    -e "s|@CLANGXX@|$CLANGXX|g" \
    -e "s|@AR@|$AR|g" \
    -e "s|@NM@|$NM|g" \
    -e "s|@RANLIB@|$RANLIB|g" \
    -e "s|@BASE_SYSROOT@|$BASE_SYSROOT|g" \
    "$SCRIPT_DIR/Toolchain-WASI.cmake.in" > "$TOOLCHAIN_FILE"

echo "[libcxx] generated toolchain file: $TOOLCHAIN_FILE"

# ----------------------------------------------------------------------
# 4) Configure with CMake
# ----------------------------------------------------------------------
echo "[libcxx] configuring…"

"$CMAKE" -B "$BUILD_DIR" -S "$LLVM_SRC/runtimes" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DLLVM_PATH="$LLVM_SRC/llvm" \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
  -DLIBCXX_ENABLE_SHARED=OFF \
  -DLIBCXX_ENABLE_STATIC=ON \
  -DLIBCXX_ENABLE_EXCEPTIONS=OFF \
  -DLIBCXX_ENABLE_RTTI=ON \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXX_ENABLE_UNWIND_TABLES=OFF \
  -DLIBCXX_ENABLE_TIME_ZONE_DATABASE=OFF \
  -DLIBCXX_HAS_MUSL_LIBC=OFF \
  -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXXABI_ENABLE_STATIC=ON \
  -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
  -DLIBCXXABI_ENABLE_RTTI=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
  -DLIBCXXABI_ENABLE_STATIC_UNWINDER=OFF \
  -DLIBCXXABI_ENABLE_UNWIND_TABLES=OFF \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBCXXABI_LIBCXX_PATH="$LLVM_SRC/libcxx" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
  -DCMAKE_CXX_COMPILER_WORKS=1 \
  -DCMAKE_C_COMPILER_WORKS=1

# ----------------------------------------------------------------------
# 5) Build and install
# ----------------------------------------------------------------------
echo "[libcxx] building…"
"$CMAKE" --build "$BUILD_DIR" --target install -j"$JOBS"

# ----------------------------------------------------------------------
# 6) Copy headers and libs to sysroot overlay
# ----------------------------------------------------------------------
echo "[libcxx] installing to sysroot overlay…"

# Headers: overlay/usr/include/c++/v1/ (merge step puts them at include/wasm32-wasi/c++/v1/)
mkdir -p "$APPS_OVERLAY/usr/include/c++"
cp -r "$INSTALL_DIR/include/c++/"* "$APPS_OVERLAY/usr/include/c++/"

# Static libraries
mkdir -p "$APPS_OVERLAY/usr/lib/wasm32-wasi"
cp "$INSTALL_DIR/lib/libc++.a"    "$APPS_OVERLAY/usr/lib/wasm32-wasi/"
cp "$INSTALL_DIR/lib/libc++abi.a" "$APPS_OVERLAY/usr/lib/wasm32-wasi/"

echo
echo "[libcxx] build complete. Outputs:"
echo "  headers: $APPS_OVERLAY/usr/include/c++/"
echo "  libs:    $APPS_OVERLAY/usr/lib/wasm32-wasi/"
ls -lh "$APPS_OVERLAY/usr/lib/wasm32-wasi/libc++"* || true
