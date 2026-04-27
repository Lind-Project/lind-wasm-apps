#!/bin/bash
WASM_MAIN_LDFLAGS="-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low"
WASM_SHARED_LDFLAGS="-Wl,--import-memory,--shared-memory,--export-dynamic,--experimental-pic,--unresolved-symbols=import-dynamic,-shared"
BARE_CC="${CLANG_BIN} -pthread --target=wasm32-unknown-wasi --sysroot ${SYSROOT} -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC"

MAKE_OVERRIDES=(
  AR="llvm-ar"
  ARFLAGS="crs"
  BLDSHARED="${BARE_CC} ${WASM_SHARED_LDFLAGS}"
  LINKFORSHARED="${WASM_MAIN_LDFLAGS}"
  ENSUREPIP=no
  MODULE__HMAC_LDFLAGS="Modules/_hacl/Hacl_HMAC.o Modules/_hacl/Hacl_Streaming_HMAC.o"
)
make "${MAKE_OVERRIDES[@]}" test
