#!/usr/bin/env bash
set -euo pipefail

# Cross-compile OpenSSL as static libraries for wasm32-wasi (LindWasm).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${LIND_WASM_ROOT:=${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)/lind-wasm}}"

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
LLVM_BIN="${LLVM_BIN:-$(ls -d "$LIND_WASM_ROOT"/clang+llvm-*/bin 2>/dev/null | head -n1)}"

if [[ -z "${LLVM_BIN}" || ! -x "$LLVM_BIN/clang" ]]; then
  echo "[openssl] ERROR: LLVM not found under $LIND_WASM_ROOT" >&2; exit 1
fi
if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[openssl] ERROR: sysroot headers missing at $BASE_SYSROOT" >&2; exit 1
fi

LIND_DYLINK="${LIND_DYLINK:-0}"
LIND_WASM_OPT="${LIND_WASM_OPT:-$LIND_WASM_ROOT/scripts/bin/lind-wasm-opt}"

CC_WASI="$LLVM_BIN/clang --target=wasm32-unknown-wasi --sysroot=$BASE_SYSROOT"
AR="$LLVM_BIN/llvm-ar"
RANLIB="$LLVM_BIN/llvm-ranlib"

OVERLAY="$REPO_ROOT/build/sysroot_overlay"
INSTALL_DIR="$REPO_ROOT/build/openssl_wasi_install"
mkdir -p "$OVERLAY/usr/lib/wasm32-wasi" "$OVERLAY/usr/include"

echo "[openssl] CC=$CC_WASI"
pushd "$REPO_ROOT/openssl" >/dev/null

make distclean || true

# ---------------------------------------------------------
# Branch OpenSSL build flags based on Dylink mode
# ---------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[openssl] Building with PIC and default visibility for Dynamic Linking..."
  SSL_CFLAGS="--sysroot=$BASE_SYSROOT -O2 -g -fPIC -fvisibility=default"
  SSL_PIC_FLAG="enable-pic"
else
  echo "[openssl] Building standard static objects for Static Linking..."
  SSL_CFLAGS="--sysroot=$BASE_SYSROOT -O2 -g"
  SSL_PIC_FLAG=""
fi

# Pass the conditional variables into the build environment
CC="$CC_WASI" AR="$AR" RANLIB="$RANLIB" \
CFLAGS="$SSL_CFLAGS" \
LDFLAGS="--sysroot=$BASE_SYSROOT" \
./Configure linux-generic32 \
  $SSL_PIC_FLAG \
  no-asm no-shared no-dso no-async \
  no-engine no-afalgeng no-ui-console no-tests \
  --prefix="$INSTALL_DIR" --openssldir="$INSTALL_DIR/ssl"

make -j build_libs

cp libssl.a "$OVERLAY/usr/lib/wasm32-wasi/"
cp libcrypto.a "$OVERLAY/usr/lib/wasm32-wasi/"
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libssl.a"
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libcrypto.a"

rsync -a include/openssl/ "$OVERLAY/usr/include/openssl/"

popd >/dev/null
if [[ "$LIND_DYLINK" != "1" ]]; then
	echo "[openssl] done → $OVERLAY/usr/lib/wasm32-wasi/libssl.a, libcrypto.a"
	exit 0
fi

mkdir -p "$OVERLAY/lib"
ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"

STATIC_LIB="$OVERLAY/usr/lib/wasm32-wasi/libssl.a"
DYNAMIC_LIB_WASM="$OVERLAY/usr/lib/wasm32-wasi/libssl.wasm"
DYNAMIC_LIB_OPT="$OVERLAY/usr/lib/wasm32-wasi/libssl.opt.wasm"
DYNAMIC_LIB_OPT_CWASM="$OVERLAY/usr/lib/wasm32-wasi/libssl.opt.cwasm"
DYNAMIC_STAGED_LIB="$OVERLAY/lib/libssl.so"

"$LLVM_BIN/clang" \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot "$BASE_SYSROOT" \
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
    -g -O0 -o "$DYNAMIC_LIB_WASM" || { echo "[openssl] ERROR: clang compilation failed" >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'; Exiting.." >&2
  exit 1
fi

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional || { echo "[openssl] ERROR: add-export-tool tls failed" >&2; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional || { echo "[openssl] ERROR: add-export-tool global failed" >&2; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM"  __stack_pointer global __stack_pointer optional || { echo "[openssl] ERROR: add-export-tool stack pointer failed" >&2; exit 1; }


"$LIND_WASM_OPT" --target=library --fpcast-emu "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" || { echo "[openssl] ERROR: lind-wasm-opt failed on '$DYNAMIC_LIB_OPT'; Exiting.." >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'; Exiting.." >&2
  exit 1
fi

# do precompile
$LIND_WASM_ROOT/scripts/bin/lind_compile --precompile-only "$DYNAMIC_LIB_OPT" || { echo "[openssl] ERROR: lind_compile failed on '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2
  exit 1
fi

cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
echo "[openssl] Dynamic shared library staged as $DYNAMIC_STAGED_LIB"

STATIC_LIB="$OVERLAY/usr/lib/wasm32-wasi/libcrypto.a"
DYNAMIC_LIB_WASM="$OVERLAY/usr/lib/wasm32-wasi/libcrypto.wasm"
DYNAMIC_LIB_OPT="$OVERLAY/usr/lib/wasm32-wasi/libcrypto.opt.wasm"
DYNAMIC_LIB_OPT_CWASM="$OVERLAY/usr/lib/wasm32-wasi/libcrypto.opt.cwasm"
DYNAMIC_STAGED_LIB="$OVERLAY/lib/libcrypto.so"
"$LLVM_BIN/clang" \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot "$BASE_SYSROOT" \
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
    -g -O0 -o "$DYNAMIC_LIB_WASM" || { echo "[openssl] ERROR: clang compilation failed" >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'; Exiting.." >&2
  exit 1
fi

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional || { echo "[openssl] ERROR: add-export-tool tls failed" >&2; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional || { echo "[openssl] ERROR: add-export-tool global failed" >&2; exit 1; }

"$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM"  __stack_pointer global __stack_pointer optional || { echo "[openssl] ERROR: add-export-tool stack pointer failed" >&2; exit 1; }


"$LIND_WASM_OPT" --target=library --fpcast-emu "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" || { echo "[openssl] ERROR: lind-wasm-opt failed on '$DYNAMIC_LIB_OPT'; Exiting.." >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'; Exiting.." >&2
  exit 1
fi

# do precompile
$LIND_WASM_ROOT/scripts/bin/lind_compile --precompile-only "$DYNAMIC_LIB_OPT" || { echo "[openssl] ERROR: lind_compile failed on '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2; exit 1; }

if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
  echo "[openssl] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2
  exit 1
fi

cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
echo "[openssl] Dynamic shared library staged as $DYNAMIC_STAGED_LIB"

