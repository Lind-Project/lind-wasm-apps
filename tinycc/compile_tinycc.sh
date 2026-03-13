#!/bin/bash

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

# opt and precompile
echo "Precompiling"
lind_compile --opt-only tcc.wasm -o tcc.opt.wasm
if [ -s "tcc.opt.wasm" ]; then
	echo "Generating cwasm from opt.wasm"
	lind_compile --precompile-only tcc.opt.wasm -o tcc.cwasm
else
	echo "Generating cwasm from wasm"
	lind_compile --precompile-only tcc.wasm -o tcc.cwasm
fi

# copy to app build folder preserving the directory structure
mkdir -p $APPS_ROOT/build/tinycc/bin
mkdir -p $APPS_ROOT/build/tinycc/usr/local/bin/tcc/
if [ -s "tcc.cwasm" ]; then
	cp tcc.cwasm $APPS_ROOT/build/tinycc/bin/tcc
elif [ -s "tcc.wasm" ]; then
	cp tcc.wasm $APPS_ROOT/build/tinycc/bin/tcc
else
	echo "No wasm binary created"
	exit 1
fi

#libtcc1.a is required to run tinycc
cp libtcc1.a $APPS_ROOT/build/tinycc/usr/local/bin/tcc/

#These headers are required to compile C programs using tinycc
tar -xvzf tcc_headers.tar.gz
rsync -a "${SCRIPT_DIR}/tcc_headers/" "$APPS_ROOT/build/tinycc/"

#While running tinycc to compile C programs as 32-bit binaries, it
#requires 32-bit versions of libc.so, ld.so, libc_nonshared.a and crt object files
#in the search path. Since tinycc is run within lindfs/ it will search in paths
#relative to lindfs. We first create these paths with respect to the build folder
#Later at 'make install' stage, all the files within the build folder copied to lindfs folder

mkdir -p "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/crt*.o "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc.so* "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/ld-linux.so.2 "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc_nonshared.a "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/"

#While running tinycc, it checks for libc.so which is a stub that looks for ld.so, libc_nonshared.a and libc.so.6. We change the absolute paths of these which were with respect to the root filesystem, so tinycc can locate these files with respect to lindfs 
sed -i 's|[^ ]*/libc\.so\.6|libc.so.6|g; s|[^ ]*/libc_nonshared\.a|libc_nonshared.a|g; s|[^ ]*/ld-linux\.so\.2|ld-linux.so.2|g' "$APPS_ROOT/build/tinycc/usr/lib/i386-linux-gnu/libc.so"

#To run dynamically linked executable using tinycc, it expects its linker at /lib/ld-linux.so.2, hence we map the 32-bit linker to that file
sudo ln -s /usr/i686-linux-gnu/lib/ld-linux.so.2 /lib/ld-linux.so.2
