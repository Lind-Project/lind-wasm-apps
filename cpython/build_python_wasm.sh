#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd $SCRIPT_DIR
# build native python if not exist
if [ ! -f "./build-native/python" ]; then
  ./build_python_native.sh
fi

# create wasi related placeholder library
llvm-ar crs "/home/lind/lind-wasm/src/glibc/sysroot/lib/wasm32-wasi/libwasi-emulated-getpid.a"
llvm-ar crs "/home/lind/lind-wasm/src/glibc/sysroot/lib/wasm32-wasi/libwasi-emulated-signal.a"
llvm-ar crs "/home/lind/lind-wasm/src/glibc/sysroot/lib/wasm32-wasi/libwasi-emulated-process-clocks.a"

# run configure if Makefile does not exist
if [ ! -f "Makefile" ]; then
  ./configure \
    --host=wasm32-unknown-wasi \
    --build=x86_64-unknown-linux-gnu \
    --with-build-python=./build-native/python \
    CC="/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang \
    -pthread \
    --target=wasm32-unknown-wasi \
    --sysroot /home/lind/lind-wasm/src/glibc/sysroot \
    -Wl,--import-memory,--export-memory,--max-memory=2147483648,-z,stack-size=1073741824,--export=__stack_pointer,--export=__stack_low -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0" \
    ac_cv_func_working_mktime=yes \
    ac_cv_func_mmap_fixed_mapped=yes \
    bash_cv_func_sigsetjmp=no \
    ac_cv_func_localeconv=no \
    ac_cv_func_uselocale=no \
    ac_cv_func_setlocale=no \
    ac_cv_func_newlocale=no \
    ac_cv_have_chflags=no \
    ax_cv_c_float_words_bigendian=no \
    ac_cv_file__dev_ptmx=no \
    ac_cv_file__dev_ptc=no \
    ac_cv_func_memfd_create=no \
    ac_cv_func_eventfd=no \
    ac_cv_func_timerfd_create=no \
    --verbose
fi

# clean up
make clean

# build python
make AR="llvm-ar" ARFLAGS="crs"

# install nescessary files into lind filesystem
make install DESTDIR=/home/lind/lind-wasm/src/tmp

# apply wasm-opt
/home/lind/lind-wasm/tools/binaryen/bin/wasm-opt --epoch-injection --asyncify -O2 --debuginfo python.wasm -o python.wasm
/home/lind/lind-wasm/src/wasmtime/target/debug/wasmtime compile python.wasm -o python.cwasm
