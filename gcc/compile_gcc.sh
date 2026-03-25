#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# GCC WASI build helper for lind-wasm-apps
#
# Cross-compiles GCC 15.2.0 (C language only) to wasm32-wasi so that cc1 can
# run inside the Lind sandbox.  The resulting compiler targets x86_64-linux-gnu
# (GCC has no wasm32 backend).
#
# High-level strategy:
#   1. Download GCC prerequisites (GMP, MPFR, MPC) into the source tree
#   2. Out-of-tree build (GCC requires this)
#   3. Configure with --host=wasm32-unknown-wasi, --target=x86_64-linux-gnu
#      Generator tools are built natively via CC_FOR_BUILD; cc1 is cross-
#      compiled to wasm32 via CC/CXX.
#   4. Build with 'make all-gcc' (compiler only, no target libraries)
#   5. Stage cc1, post-process with wasm-opt + lind-boot
#
# Prerequisites:
#   - Run 'make preflight' and ensure libc++ is in the merged sysroot
#     (run 'make libcxx merge-sysroot' or let the Makefile handle it)
#   - Native gcc/g++ must be on PATH (for CC_FOR_BUILD / CXX_FOR_BUILD)
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GCC_SRC="$APPS_ROOT/gcc"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/gcc/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[gcc] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"
: "${NM:?missing NM in $TOOL_ENV}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
CLANGXX="$LLVM_BIN_DIR/clang++"
if [[ ! -x "$CLANGXX" ]]; then
  echo "[gcc] WARN: clang++ not found; creating symlink to clang"
  ln -sf "$CLANG" "$CLANGXX"
fi

# Sanity checks
if [[ ! -d "$GCC_SRC" ]]; then
  echo "[gcc] ERROR: GCC source dir not found at '$GCC_SRC'" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[gcc] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi
# libc++ must be in the sysroot for C++ compilation
if [[ ! -f "$MERGED_SYSROOT/lib/wasm32-wasi/libc++.a" ]]; then
  echo "[gcc] ERROR: libc++.a not found in merged sysroot. Run 'make libcxx merge-sysroot' first." >&2
  exit 1
fi
# Need native gcc/g++ for building generator tools
if ! command -v gcc &>/dev/null || ! command -v g++ &>/dev/null; then
  echo "[gcc] ERROR: native gcc/g++ required for CC_FOR_BUILD but not found on PATH" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) WASM toolchain flags
# ----------------------------------------------------------------------
LIBCXX_INCLUDE="$MERGED_SYSROOT/include/wasm32-wasi/c++/v1"

# -matomics and -mbulk-memory are wasm32-only flags — they MUST live in CC/CXX
# (not CFLAGS/CXXFLAGS) because GCC's build system also passes CFLAGS/CXXFLAGS
# to CC_FOR_BUILD (native g++), which doesn't understand them.
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread -matomics -mbulk-memory"

CXX_WASM="$CLANGXX --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread -matomics -mbulk-memory \
  -stdlib=libc++ -isystem $LIBCXX_INCLUDE -fno-exceptions"

CFLAGS_WASM="-O2 -g \
  -I$MERGED_SYSROOT/include \
  -I$MERGED_SYSROOT/include/wasm32-wasi"

CXXFLAGS_WASM="$CFLAGS_WASM -isystem $LIBCXX_INCLUDE"

LDFLAGS_WASM="-Wl,--import-memory,--export-memory,--max-memory=67108864 \
  -Wl,--export=__stack_pointer,--export=__stack_low \
  -L$MERGED_SYSROOT/lib/wasm32-wasi \
  -L$MERGED_SYSROOT/usr/lib/wasm32-wasi \
  -lc++ -lc++abi"

echo "[gcc] using CLANG          = $CLANG"
echo "[gcc] using CLANGXX        = $CLANGXX"
echo "[gcc] using AR             = $AR"
echo "[gcc] LIND_WASM_ROOT       = $LIND_WASM_ROOT"
echo "[gcc] merged sysroot       = $MERGED_SYSROOT"
echo "[gcc] libc++ headers       = $LIBCXX_INCLUDE"
echo "[gcc] stage dir            = $STAGE_DIR"
echo "[gcc] CC_WASM              = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 3) Download GCC prerequisites (GMP, MPFR, MPC) if not already present
# ----------------------------------------------------------------------
pushd "$GCC_SRC" >/dev/null

if [[ ! -d gmp ]] || [[ ! -d mpfr ]] || [[ ! -d mpc ]]; then
  echo "[gcc] downloading prerequisites (GMP, MPFR, MPC)…"
  ./contrib/download_prerequisites --no-isl --no-verify
else
  echo "[gcc] prerequisites already present; skipping download."
fi

popd >/dev/null

# ----------------------------------------------------------------------
# 4) Out-of-tree build directory
# ----------------------------------------------------------------------
GCC_BUILD="$APPS_BUILD/gcc-build"
mkdir -p "$GCC_BUILD"

echo "[gcc] build dir = $GCC_BUILD"

# ----------------------------------------------------------------------
# 5) Configure GCC
# ----------------------------------------------------------------------
BUILD_TRIPLET="$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)"

echo "[gcc] configuring…"
echo "[gcc]   --build=$BUILD_TRIPLET"
echo "[gcc]   --host=wasm32-unknown-wasi"
echo "[gcc]   --target=x86_64-linux-gnu"

pushd "$GCC_BUILD" >/dev/null

"$GCC_SRC/configure" \
  --build="$BUILD_TRIPLET" \
  --host=wasm32-unknown-wasi \
  --target=x86_64-linux-gnu \
  --disable-bootstrap \
  --enable-languages=c \
  --disable-shared \
  --enable-static \
  --disable-threads \
  --disable-multilib \
  --disable-plugin \
  --disable-nls \
  --disable-libgcc \
  --disable-libssp \
  --disable-libgomp \
  --disable-libatomic \
  --disable-libquadmath \
  --disable-libvtv \
  --disable-libitm \
  --disable-libsanitizer \
  --disable-libstdc++-v3 \
  --disable-libffi \
  --disable-decimal-float \
  --disable-lto \
  --without-headers \
  --without-isl \
  --with-gnu-as \
  --with-gnu-ld \
  CC_FOR_BUILD=gcc \
  CXX_FOR_BUILD=g++ \
  AR_FOR_BUILD=ar \
  CC="$CC_WASM" \
  CXX="$CXX_WASM" \
  AR="$AR" \
  NM="$NM" \
  RANLIB="$RANLIB" \
  CFLAGS="$CFLAGS_WASM" \
  CXXFLAGS="$CXXFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM"

if [[ ! -f Makefile ]]; then
  echo "[gcc] ERROR: configure failed to produce Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 6) Build (compiler only — no target libraries)
# ----------------------------------------------------------------------
echo "[gcc] building (make all-gcc)…"
make all-gcc -j"$JOBS" V=1

popd >/dev/null

# ----------------------------------------------------------------------
# 7) Stage cc1 binary
# ----------------------------------------------------------------------
CC1_BIN="$GCC_BUILD/gcc/cc1"
if [[ ! -f "$CC1_BIN" ]]; then
  echo "[gcc] ERROR: cc1 binary not produced at '$CC1_BIN'" >&2
  exit 1
fi

CC1_WASM="$SCRIPT_DIR/cc1.wasm"
CC1_OPT_WASM="$SCRIPT_DIR/cc1.opt.wasm"
cp "$CC1_BIN" "$CC1_WASM"

echo "[gcc] cc1 binary size: $(du -h "$CC1_WASM" | cut -f1)"

# ----------------------------------------------------------------------
# 8) wasm-opt
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[gcc] running wasm-opt…"
  "$WASM_OPT" --epoch-injection --asyncify --fpcast-emu --debuginfo -O2 \
    "$CC1_WASM" -o "$CC1_OPT_WASM"
else
  echo "[gcc] ERROR: wasm-opt not found at '$WASM_OPT'; exiting." >&2
  exit 1
fi

if [[ ! -f "$CC1_OPT_WASM" ]]; then
  echo "[gcc] ERROR: Failed to generate '$CC1_OPT_WASM'; exiting." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 9) cwasm generation via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[gcc] generating cwasm via lind-boot --precompile…"
  if "$LIND_BOOT" --precompile "$CC1_OPT_WASM"; then
    CC1_OPT_CWASM="$SCRIPT_DIR/cc1.opt.cwasm"
    if [[ -f "$CC1_OPT_CWASM" ]]; then
      cp "$CC1_OPT_CWASM" "$STAGE_DIR/cc1"
      echo "[gcc] cc1 staged as $STAGE_DIR/cc1"
    else
      echo "[gcc] ERROR: No .cwasm binary generated. Exiting." >&2
      exit 1
    fi
  else
    echo "[gcc] ERROR: lind-boot --precompile failed. Exiting." >&2
    exit 1
  fi
else
  echo "[gcc] ERROR: lind-boot not found at '$LIND_BOOT'. Exiting." >&2
  exit 1
fi

popd >/dev/null 2>&1 || true

echo
echo "[gcc] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
