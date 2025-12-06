#!/usr/bin/env bash
set -euo pipefail

echo "========== coreutils → WASM build =========="

# Determine paths
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIND_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

echo "APP_ROOT : $APP_ROOT"
echo "LIND_ROOT: $LIND_ROOT"

GLIBC_SYSROOT="$LIND_ROOT/src/glibc/sysroot"
SYSROOT="$APP_ROOT/sysroot_overlay"
BUILD_DIR="$APP_ROOT/build_wasm"
OUT_DIR="$APP_ROOT/out_wasm"

CLANG="$LIND_ROOT/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"
LLVM_RANLIB="$LIND_ROOT/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ranlib"

# Use a host triple that config.sub understands
HOST_TRIPLE="riscv64-unknown-linux-gnu"
BUILD_TRIPLE="x86_64-pc-linux-gnu"

echo
echo "[STEP 1] Prepare sysroot_overlay from glibc wasm32-wasi sysroot ..."
mkdir -p "$SYSROOT"
if [ ! -d "$GLIBC_SYSROOT" ]; then
  echo "ERROR: GLIBC sysroot not found at: $GLIBC_SYSROOT"
  exit 1
fi

# Sync glibc sysroot into our local overlay (headers + libs)
rsync -a "$GLIBC_SYSROOT"/ "$SYSROOT"/
echo "[OK] sysroot_overlay at: $SYSROOT"

echo
echo "[STEP 2] Create build directory ..."
mkdir -p "$BUILD_DIR"
echo "[OK] build dir: $BUILD_DIR"

# Export toolchain for configure/make
echo
echo "[STEP 3] Setup toolchain environment ..."
export CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
export RANLIB="$LLVM_RANLIB"

# Basic optimization/debug flags
export CFLAGS="-O2 -g"

# Hack: provide internal glibc IO flags so gnulib does not hit #error
# Values are taken from glibc's historical libio.h
export CPPFLAGS="${CPPFLAGS:-} -D_IO_EOF_SEEN=0x10 -D_IO_ERR_SEEN=0x20 -D_IO_IN_BACKUP=0x100"

# Linker flags can stay mostly empty; CC already knows the target + sysroot
export LDFLAGS="${LDFLAGS:-}"

echo "CC      = $CC"
echo "CPPFLAGS= $CPPFLAGS"
echo "CFLAGS  = $CFLAGS"

echo
echo "[STEP 4] Run configure (cross-compiling to wasm via fake host=$HOST_TRIPLE) ..."
cd "$BUILD_DIR"

if [ ! -f Makefile ]; then
  "$APP_ROOT/configure" \
    --host="$HOST_TRIPLE" \
    --build="$BUILD_TRIPLE" \
    --prefix=/opt/coreutils-wasm \
    --disable-nls \
    --without-selinux || {
      echo "configure failed"
      exit 1
    }
else
  echo "Makefile already exists, skip configure."
fi

echo
echo "[STEP 5] Build coreutils with make ..."
make -j"$(nproc)"

echo
echo "[STEP 6] Install into staging directory ..."
mkdir -p "$OUT_DIR"
make install DESTDIR="$OUT_DIR"

echo
echo "[DONE] coreutils wasm build finished."
echo "Binaries are under: $OUT_DIR/opt/coreutils-wasm/bin"
