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

# GCC's build system passes CFLAGS/CXXFLAGS to BOTH the cross-compiler (CC)
# and the native build compiler (CC_FOR_BUILD).  ALL wasm-specific flags —
# target, sysroot, include paths, -matomics, -mbulk-memory, libc++ — MUST
# live in CC/CXX so that native g++ never sees them.
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT \
  -pthread -matomics -mbulk-memory \
  -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"

CXX_WASM="$CLANGXX --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT \
  -pthread -matomics -mbulk-memory \
  -stdlib=libc++ -isystem $LIBCXX_INCLUDE -fno-exceptions \
  -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"

# CFLAGS/CXXFLAGS must contain ONLY portable flags that native g++ also
# understands — no paths, no wasm flags.
# Use -Os to minimize binary size — cc1 at -O2 is ~183MB which causes
# wasm-opt --asyncify to OOM in Docker (no swap available).
CFLAGS_WASM="-Os"
CXXFLAGS_WASM="-Os"

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
fi

# GMP/MPFR/MPC ship their own config.sub which is too old to know about
# wasm32-wasi.  Overwrite with GCC's version which does.
echo "[gcc] patching config.sub in prerequisites…"
for dir in gmp mpfr mpc; do
  if [[ -f "$dir/config.sub" ]]; then
    cp -f config.sub "$dir/config.sub"
    echo "[gcc]   updated $dir/config.sub"
  fi
  if [[ -f "$dir/configfsf.sub" ]]; then
    cp -f config.sub "$dir/configfsf.sub"
    echo "[gcc]   updated $dir/configfsf.sub"
  fi
done

# Patch MPFR's configure to disable float128.
# MPFR detects __float128 (clang accepts it), then adds -D_Float128=__float128
# which conflicts with the WASI sysroot's "typedef __float128 _Float128;"
# in bits/floatn.h.  MPFR's configure runs during 'make all-gcc', so we
# patch the source-level configure script directly.
MPFR_CONFIGURE="$GCC_SRC/mpfr/configure"
if [[ -f "$MPFR_CONFIGURE" ]]; then
  if ! grep -q 'PATCHED_FOR_WASI' "$MPFR_CONFIGURE"; then
    echo "[gcc] [patch] disabling float128 in MPFR configure…"
    # Insert enable_float128=no right after the shebang line
    sed -i '1 a\enable_float128=no  # PATCHED_FOR_WASI' "$MPFR_CONFIGURE"
    echo "[gcc] [patch] verify:"
    head -3 "$MPFR_CONFIGURE"
  else
    echo "[gcc] MPFR configure already patched for WASI."
  fi
else
  echo "[gcc] WARN: MPFR configure not found at $MPFR_CONFIGURE"
fi

# Also guard the sysroot's bits/floatn.h so the typedef doesn't conflict
# when _Float128 is pre-defined as a macro (by MPFR or anything else).
FLOATN_H="$MERGED_SYSROOT/include/wasm32-wasi/bits/floatn.h"
if [[ -f "$FLOATN_H" ]] && ! grep -q 'PATCHED_FOR_WASI' "$FLOATN_H"; then
  echo "[gcc] [patch] guarding _Float128 typedef in sysroot floatn.h…"
  sed -i 's|^typedef __float128 _Float128;|/* PATCHED_FOR_WASI */\n#ifndef _Float128\ntypedef __float128 _Float128;\n#endif|' "$FLOATN_H"
fi

popd >/dev/null

# ----------------------------------------------------------------------
# 4) Out-of-tree build directory
# ----------------------------------------------------------------------
GCC_BUILD="$APPS_BUILD/gcc-build"
mkdir -p "$GCC_BUILD"

echo "[gcc] build dir = $GCC_BUILD"

# ----------------------------------------------------------------------
# 4b) Create config.site to override broken sub-configure detections
# ----------------------------------------------------------------------
# MPFR's configure detects __float128 support, then adds -D_Float128=__float128.
# But the WASI sysroot already has "typedef __float128 _Float128;" in
# bits/floatn.h, so the macro turns it into "typedef __float128 __float128;"
# which is invalid.  Disable float128 in MPFR via configure cache.
GCC_CONFIG_SITE="$GCC_BUILD/config.site"
cat > "$GCC_CONFIG_SITE" << 'EOF'
# Overrides for wasm32-wasi cross-compilation
mpfr_cv_want_float128=no
EOF
export CONFIG_SITE="$GCC_CONFIG_SITE"
echo "[gcc] created config.site: $GCC_CONFIG_SITE"

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
  CFLAGS_FOR_BUILD="-O2 -g" \
  CXXFLAGS_FOR_BUILD="-O2 -g" \
  LDFLAGS_FOR_BUILD="" \
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
  # cc1 is very large — strip debug info first to reduce memory pressure
  # during asyncify, then run asyncify + epoch-injection in a single pass.
  CC1_STRIPPED="$SCRIPT_DIR/cc1.stripped.wasm"
  echo "[gcc] stripping debug info to reduce wasm-opt memory usage…"
  "$WASM_OPT" --strip-debug "$CC1_WASM" -o "$CC1_STRIPPED"
  echo "[gcc] stripped size: $(du -h "$CC1_STRIPPED" | cut -f1)"

  echo "[gcc] running wasm-opt (epoch-injection + asyncify)…"
  "$WASM_OPT" --epoch-injection --asyncify \
    "$CC1_STRIPPED" -o "$CC1_OPT_WASM"
  rm -f "$CC1_STRIPPED"
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
