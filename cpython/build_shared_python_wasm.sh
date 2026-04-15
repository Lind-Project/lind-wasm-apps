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
CLANG_BIN="${LIND_WASM_ROOT}/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"

PYTHON_OUT_DIR="$APPS_ROOT/build/cpython"
STATIC_LIB="$BUILD_WASM/libpython3.14.a"
DYNAMIC_LIB_WASM="$BUILD_WASM/libpython3.14.wasm"
DYNAMIC_LIB_OPT="$BUILD_WASM/libpython3.14.opt.wasm"
DYNAMIC_LIB_OPT_CWASM="$BUILD_WASM/libpython3.14.opt.cwasm"
DYNAMIC_STAGED_LIB="$PYTHON_OUT_DIR/lib/libpython3.14.so"
mkdir -p "$PYTHON_OUT_DIR/lib"
mkdir -p "$PYTHON_OUT_DIR/usr/local/bin"
# compile shared libpython
$CLANG_BIN \
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
    "$STATIC_LIB" \
    -Wl,--no-whole-archive \
    "$LIND_WASM_ROOT/src/glibc/build/lind_debug.o" \
    -g -O0 -o "$DYNAMIC_LIB_WASM" 	|| { echo "[python] ERROR: clang compilation failed"; exit 1; }


if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
  echo "[python] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'; Exiting.."
  exit 1
fi

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional || { echo "[python] ERROR: add-export-tool tls failed"; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional || { echo "[python] ERROR: add-export-tool global failed"; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM"  __stack_pointer global __stack_pointer optional || { echo "[python] ERROR: add-export-tool stack pointer failed"; exit 1; }


$WASM_OPT --enable-bulk-memory --enable-threads --epoch-injection --pass-arg=epoch-import --asyncify --pass-arg=asyncify-import-globals -O2 --debuginfo "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" || { echo "[python] ERROR: wasm-opt failed on '$DYNAMIC_LIB_OPT'; Exiting.."; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
  echo "[python] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'; Exiting.."
  exit 1
fi

# do precompile
$LIND_WASM_ROOT/scripts/lind_compile --precompile-only "$DYNAMIC_LIB_OPT"|| { echo "[python] ERROR: lind_compile failed on '$DYNAMIC_LIB_OPT_CWASM'; Exiting.."; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
  echo "[python] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'; Exiting.."
  exit 1
fi

cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
echo "[python] Dynamic shared library staged as $DYNAMIC_STAGED_LIB"



#compile shared python

PYTHON_WASM="$BUILD_WASM/python_shared.wasm"
PYTHON_OPT_WASM="$BUILD_WASM/python_shared.opt.wasm"
PYTHON_OPT_CWASM="$BUILD_WASM/python_shared.opt.cwasm"

$CLANG_BIN \
    -pthread \
    -fPIC \
    --target=wasm32-unknown-wasi \
    --sysroot "$SYSROOT" \
    -Wl,-pie \
    -Wl,--import-table \
    -Wl,--import-memory \
    -Wl,--export-memory \
    -Wl,--shared-memory \
    -Wl,--max-memory=67108864 \
    -Wl,--export=__stack_pointer \
    -Wl,--export=__stack_low \
    -Wl,--export=__wasm_call_ctors \
    -Wl,--export-if-defined=__wasm_init_tls \
    -Wl,--export=__tls_base \
    -Wl,--allow-undefined \
    -Wl,--unresolved-symbols=import-dynamic \
    -D _FILE_OFFSET_BITS=64 \
    -D __USE_LARGEFILE64 \
    -g -O0 \
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


if [[ -x "$WASM_OPT" ]]; then
  echo "[python] running wasm-opt (best-effort)..."
  
  "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
      --asyncify --pass-arg=asyncify-import-globals \
      --debuginfo \
      "$PYTHON_WASM" -o "$PYTHON_OPT_WASM" || true
else
  echo "[python] ERROR: wasm-opt not found; skipping optimization step and exiting."
  exit 1
fi

if [[ ! -f "$PYTHON_OPT_WASM" ]]; then
  echo "[python] ERROR: Failed to generate $PYTHON_OPT_WASM; Exiting.."
  exit 1
fi

echo "[python] adding dylink exports via add-export-tool..."
"$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
"$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
"$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __stack_pointer global __stack_pointer

# 7. cwasm generation via lind-boot (best-effort)
###############################################################################
if [[ -x "$LIND_BOOT" ]]; then
  echo "=> generating cwasm via lind-boot --precompile..."

  # Pass the (potentially optimized) Wasm file to lind-boot
  if "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM"; then

    if [[ -f "$PYTHON_OPT_CWASM" ]]; then
      cp "$PYTHON_OPT_CWASM" "$PYTHON_OUT_DIR/usr/local/bin/python"
      echo "[python] python staged as $PYTHON_OUT_DIR/usr/local/bin/python"
    else
      echo "[python] ERROR: No .cwasm binary generated and no binaries copied to the build folder. Exiting .."
      exit 1
    fi

  else
    echo "[python] ERROR: lind-boot --precompile failed; skipping cwasm generation."
    echo "[python] ERROR: No binaries copied to the build folder. Exiting.."
    exit 1
  fi
else
  echo "[python] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  echo "[python] ERROR: No binaries copied to the build folder. Exiting.."
  exit 1
fi

echo
echo "[python] build complete. Outputs under:"
echo "  $PYTHON_OUT_DIR"
ls -lh "$PYTHON_OUT_DIR" || true


