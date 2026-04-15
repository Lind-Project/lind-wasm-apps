#!/bin/bash

# This build script produces wasm tinycc compiler that  can compile C programs to 32-bit ELF binaries (i386 target). 

# libtcc.a is a shared library that is required to run tinycc. Since the target is i386, libtcc.a is also compiled as i386. 

# The required header files, shared libraries and other files (libc.so, ld.so, libc_nonshared.a, crt1.o) which are required to run tinycc is also copied to the build/ folder. 

# To run dynamically linked executables produced by tinycc, dynamic linker is used. Since the executable is run natively, we provide a symbolic link to the 32-bit dynamic linker within /lib of the root filesystem so that the kernel can locate the dynamic linker.

set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi
SYSROOT="${LIND_WASM_ROOT}/build/sysroot"
LINDFS="${LIND_WASM_ROOT}/lindfs"
LIND_BOOT="${LIND_WASM_ROOT}/src/lind-boot/target/debug/lind-boot"

CLANG_BIN="${LIND_WASM_ROOT}/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"
STAGE_DIR="$APPS_ROOT/build/tinycc"

mkdir -p "$STAGE_DIR"

CFLAGS_WASM="--target=wasm32-wasi -g -O0 --sysroot=$SYSROOT -pthread -matomics -mbulk-memory -fno-pie -fvisibility=default -fno-builtin"

LDFLAGS_WASM="--target=wasm32-wasi -g -O0 --sysroot=$SYSROOT -static -Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864,--export="__stack_pointer",--export=__stack_low,--export=__tls_base"

cd $SCRIPT_DIR

./configure \
  --cpu=i386 \
  --cc=$CLANG_BIN \
  --extra-cflags="$CFLAGS_WASM" \
  --extra-ldflags="$LDFLAGS_WASM" \
  --enable-static --enable-cross --extra-libs=""

echo "CONFIG_ldl=no" >> config.mak

make tcc

if [ -f "tcc" ]; then
    mv tcc tcc.wasm
else
    echo "Error: tcc binary was not generated!"
    exit 1
fi

# use gcc to compile libtcc1.c to object file, then archive it into a static library
# `libtcc1` is used by tinycc wasm binary for compiling C programs. Hence `libtcc1` is compiled as an x86  ELF binary in align with the target architecture of tinycc
gcc -m32 -O2 -DTCC_TARGET_I386 -c lib/libtcc1.c -o libtcc1.o
ar rcs libtcc1.a libtcc1.o

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
TCC_WASM="$SCRIPT_DIR/tcc.wasm"
TCC_OPT_WASM="$SCRIPT_DIR/tcc.opt.wasm"

# ----------------------------------------------------------------------
# 8) wasm-opt (best-effort)
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[tinycc] running wasm-opt (asyncify + optimization)…"
  "$WASM_OPT" \
    --epoch-injection \
    --asyncify \
    --debuginfo \
    -O2 \
    "$TCC_WASM" \
    -o "$TCC_OPT_WASM" || true
else
  echo "[tinycc] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization. Exiting.."
  exit 1
fi

if [[ ! -f "$TCC_OPT_WASM" ]]; then
  echo "[tinycc] ERROR: Failed to generate "$TCC_OPT_WASM"; Exiting.."
  exit 1
fi

# ----------------------------------------------------------------------
# 9) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[git] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$TCC_OPT_WASM"; then
  
    TCC_OPT_CWASM="$SCRIPT_DIR/tcc.opt.cwasm"

    #Staging the final .cwasm binary to the build folder
    if [[ -f "$TCC_OPT_CWASM" ]]; then
      mkdir -p $STAGE_DIR/bin
      cp "$TCC_OPT_CWASM" "$STAGE_DIR/bin/tinycc"
      echo "[tinycc] tinycc staged as $STAGE_DIR/bin/tinycc"
    else
      echo "[tinycc] ERROR: No .cwasm binary generated and no binaries copied to the build folder. Exiting.. "
      exit 1
    fi
  else
    echo "[tinycc] ERROR: lind-boot --precompile failed; skipping cwasm generation."
    echo "[tinycc] ERROR: No binaries copied to the build folder. Exiting.."
    exit 1
  fi
else
  echo "[tinycc] ERROR: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  echo "[tinycc] ERROR: No binaries copied to the build folder. Exiting.."
  exit 1
fi

mkdir -p $STAGE_DIR/usr/local/lib/tcc
#libtcc1.a is required to run tinycc
cp libtcc1.a $STAGE_DIR/usr/local/lib/tcc/

#These headers are required to compile C programs using tinycc
tar -xvzf tcc_headers.tar.gz
rsync -a "${SCRIPT_DIR}/tcc_headers/" "$STAGE_DIR/"

#While running tinycc to compile C programs as 32-bit binaries, it
#requires 32-bit versions of libc.so, ld.so, libc_nonshared.a and crt object files
#in the search path. Since tinycc is run within lindfs/ it will search in paths
#relative to lindfs. We first create these paths with respect to the build folder
#Later at 'make install' stage, all the files within the build folder copied to lindfs folder

mkdir -p "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/crt*.o "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc.so* "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/ld-linux.so.2 "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc_nonshared.a "$STAGE_DIR/usr/lib/i386-linux-gnu/"

#While running tinycc, it checks for libc.so which is a stub that looks for ld.so, libc_nonshared.a and libc.so.6. We change the absolute paths of these which were with respect to the root filesystem, so tinycc can locate these files with respect to lindfs 
sed -i 's|[^ ]*/libc\.so\.6|libc.so.6|g; s|[^ ]*/libc_nonshared\.a|libc_nonshared.a|g; s|[^ ]*/ld-linux\.so\.2|ld-linux.so.2|g' "$STAGE_DIR/usr/lib/i386-linux-gnu/libc.so"

#To run dynamically linked executable using tinycc, it expects its linker at /lib/ld-linux.so.2, hence we map the 32-bit linker to that file
if [ ! -e /lib/ld-linux.so.2 ]; then
    sudo ln -s /usr/i686-linux-gnu/lib/ld-linux.so.2 /lib/ld-linux.so.2
fi
