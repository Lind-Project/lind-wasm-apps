#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"

BUILD_WASM="$SCRIPT_DIR/build-wasm"
SYSROOT="$LIND_WASM_ROOT/src/glibc/sysroot"
LIND_BOOT="${LIND_WASM_ROOT}/src/lind-boot/target/debug/lind-boot"

# compile shared libpython
clang \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot "$SYSROOT" \
    -fvisibility=default \
    -Wl,--import-memory \
    -Wl,--shared-memory \
    -Wl,--export-dynamic \
    -Wl,--experimental-pic \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,-shared \
    -Wl,--whole-archive \
    "$BUILD_WASM/libpython3.14.a" \
    -Wl,--no-whole-archive \
    -g -O0 -o "$BUILD_WASM/libpython3.14.wasm" "$LIND_WASM_ROOT/src/glibc/build/lind_debug.o"	

#Apply relocations and copy the shared library to lindfs
mkdir -p "$LINDFS_ROOT/lib"
$LIND_WASM_ROOT/scripts/append_tls_relocs_export.sh $BUILD_WASM/libpython3.14.wasm $LINDFS_ROOT/lib/libpython3.14.so

#compile shared python
clang \
    -pthread \
    -fPIC \
    --target=wasm32-unknown-wasi \
    --sysroot "$SYSROOT" \
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
    -o "$BUILD_WASM/python_shared.wasm" \
    "$BUILD_WASM/Programs/python.o" \
    "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA2.a" \
    "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA1.a" \
    "$BUILD_WASM/Modules/expat/libexpat.a" \
    "$BUILD_WASM/Modules/_hacl/libHacl_Hash_MD5.a" \
    "$BUILD_WASM/Modules/_hacl/libHacl_Hash_BLAKE2.a" \
    "$BUILD_WASM/Modules/_decimal/libmpdec/libmpdec.a" \
    "$BUILD_WASM/Modules/_hacl/libHacl_HMAC.a" \
    "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA3.a" \
    -ldl -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -lpthread -lm

echo "=> Copying python_shared.wasm to lindfs..."
mkdir -p "$LINDFS_ROOT/bin"
cp "$BUILD_WASM/python_shared.wasm" "$LINDFS_ROOT/bin/python.wasm"


# Since currently dynamic loading doesn't support signals, we do not apply
# optimizations and directly produce .cwasm from .wasm

"$LIND_BOOT" --precompile "$BUILD_WASM/python_shared.wasm"
cp "$BUILD_WASM/python_shared.cwasm" "$LINDFS_ROOT/bin/python.cwasm"

# --- Optimization & Precompilation Pipeline ---
#echo "=> Running wasm-opt (best-effort)..."
#TARGET_WASM="python_shared.wasm"
#WASM_OPT="$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt"
#if [[ -x "$WASM_OPT" ]]; then
#    "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo \
#        "$BUILD_WASM/python_shared.wasm" -o "$BUILD_WASM/python_shared.opt.wasm"

#    TARGET_WASM="python_shared.opt.wasm"
#else
#    echo "=> NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization step."
#fi

#echo "=> Generating cwasm via lind-boot --precompile..."
#if [[ -x "$LIND_BOOT" ]]; then
#    pushd "$BUILD_WASM" > /dev/null

#    if "$LIND_BOOT" --precompile "$TARGET_WASM"; then
#        OPT_CWASM="${TARGET_WASM%.wasm}.cwasm"
#        CLEAN_CWASM="${OPT_CWASM/.opt/}"

#        if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
#            mv "$OPT_CWASM" "$CLEAN_CWASM"
#        fi

#        echo "=> Successfully generated $CLEAN_CWASM"
#        cp "$CLEAN_CWASM" "$LINDFS_ROOT/bin/python.cwasm"
#    else
#        echo "=> WARNING: lind-boot --precompile failed."
#    fi

#    popd > /dev/null
#else
#    echo "=> NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
#fi

echo "=> Shared build and installation complete!"
