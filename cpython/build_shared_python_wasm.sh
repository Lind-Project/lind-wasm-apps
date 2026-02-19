#!/bin/bash
set -euo pipefail

# compile shared libpython
clang \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot /home/lind/lind-wasm/src/glibc/sysroot \
    -fvisibility=default \
    -Wl,--import-memory \
    -Wl,--shared-memory \
    -Wl,--export-dynamic \
    -Wl,--experimental-pic \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,-shared \
    -Wl,--whole-archive \
    libpython3.14.a \
    -Wl,--no-whole-archive \
    -g -O0 -o libpython3.14.wasm /home/lind/lind-wasm/src/glibc/build/lind_debug.o

clang \
    -pthread \
    -fPIC \
    --target=wasm32-unknown-wasi \
    --sysroot /home/lind/lind-wasm/src/glibc/sysroot \
    -Wl,-pie \
    -Wl,--import-table \
    -Wl,--import-memory \
    -Wl,--export-memory \
    -Wl,--max-memory=67108864 \
    -Wl,--export=__stack_pointer \
    -Wl,--export=__stack_low \
    -Wl,--allow-undefined \
    -Wl,--unresolved-symbols=import-dynamic \
    -D _FILE_OFFSET_BITS=64 \
    -D __USE_LARGEFILE64 \
    -g -O0 \
    -z stack-size=16777216 \
    -Wl,--initial-memory=41943040 \
    -o python.wasm Programs/python.o Modules/_hacl/libHacl_Hash_SHA2.a Modules/_hacl/libHacl_Hash_SHA1.a Modules/expat/libexpat.a Modules/_hacl/libHacl_Hash_MD5.a Modules/_hacl/libHacl_Hash_BLAKE2.a Modules/_decimal/libmpdec/libmpdec.a Modules/_hacl/libHacl_HMAC.a Modules/_hacl/libHacl_Hash_SHA3.a -ldl -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -lpthread -lm