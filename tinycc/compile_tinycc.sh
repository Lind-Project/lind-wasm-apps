#!/bin/bash

./configure \
  --cpu=i386 \
  --cc="/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang" \
  --extra-cflags="--target=wasm32-wasi -g -O0 --sysroot=/home/lind/lind-wasm/build/sysroot -pthread -matomics -mbulk-memory -fno-pie -fvisibility=default -fno-builtin" \
  --extra-ldflags="--target=wasm32-wasi -g -O0 --sysroot=/home/lind/lind-wasm/build/sysroot -static -Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864,--export="__stack_pointer",--export=__stack_low,--export=__tls_base" \
  --enable-static --enable-cross --extra-libs=""

echo "CONFIG_ldl=no" >> config.mak

make

# use gcc to compile libtcc1.c to object file, then archive it into a static library
gcc -m32 -O2 -DTCC_TARGET_I386 -c lib/libtcc1.c -o libtcc1.o
ar rcs libtcc1.a libtcc1.o

# opt and precompile
lind_compile --opt-only tcc.wasm -o tcc.cwasm
lind_compile --precompile-only tcc.wasm -o tcc.cwasm

# copy
mkdir -p /home/lind/lind-wasm/lindfs/usr/local/lib/tcc/
cp tcc.cwasm ../lindfs/
cp libtcc1.a /home/lind/lind-wasm/lindfs/usr/local/lib/tcc/
