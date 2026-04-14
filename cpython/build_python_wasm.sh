#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi
SYSROOT="${LIND_WASM_ROOT}/src/glibc/sysroot"
LINDFS="${LIND_WASM_ROOT}/lindfs"
LIND_BOOT="${LIND_WASM_ROOT}/src/lind-boot/target/debug/lind-boot"
WASM_OPT="${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt"

CLANG_BIN="${LIND_WASM_ROOT}/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"

LIND_DYLINK="${LIND_DYLINK:-0}"
PYTHON_OUT_DIR="$APPS_ROOT/build/cpython"

cd $SCRIPT_DIR

echo "Starting python build process..."

# build native python if not exist
if [ ! -f "./build-native/python" ]; then
  echo "Building native python"
  ./build_python_native.sh
fi

# create wasi related placeholder library
llvm-ar crs "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-getpid.a"
llvm-ar crs "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-signal.a"
llvm-ar crs "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-process-clocks.a"

mkdir -p build-wasm
cd build-wasm

# run configure if Makefile does not exist
if [ ! -f "Makefile" ]; then
  ../configure \
    --host=wasm32-unknown-wasi \
    --build=x86_64-unknown-linux-gnu \
    --with-build-python=../build-native/python \
    CC="${CLANG_BIN} \
    -pthread \
    --target=wasm32-unknown-wasi \
    --sysroot ${SYSROOT} \
    -Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC" \
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

# build python
make AR="llvm-ar" ARFLAGS="crs"

# install necessary files into lind filesystem
sudo make install DESTDIR="${LINDFS}"

# apply wasm-opt
# /home/lind/lind-wasm/tools/binaryen/bin/wasm-opt --epoch-injection --asyncify -O2 --debuginfo python.wasm -o python.wasm
# /home/lind/lind-wasm/src/wasmtime/target/debug/wasmtime compile python.wasm -o python.cwasm

# 6. Apply wasm-opt (best-effort)
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
    exit 0
fi

PYTHON_WASM="$SCRIPT_DIR/build-wasm/python.wasm"
PYTHON_OPT_WASM="$SCRIPT_DIR/build-wasm/python.opt.wasm"
PYTHON_OPT_CWASM="$SCRIPT_DIR/build-wasm/python.opt.cwasm"

if [[ -x "$WASM_OPT" ]]; then
  echo "[python] running wasm-opt (best-effort)..."
  
  "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo \
    "$PYTHON_WASM" -o "$PYTHON_OPT_WASM"
else
  echo "[python] ERROR: wasm-opt not found; skipping optimization step and exiting."
  exit 1
fi

if [[ ! -f "$PYTHON_OPT_WASM" ]]; then
  echo "[python] ERROR: Failed to generate $PYTHON_OPT_WASM; Exiting.."
  exit 1
fi

# 7. cwasm generation via lind-boot (best-effort)
###############################################################################
if [[ -x "$LIND_BOOT" ]]; then
  echo "=> generating cwasm via lind-boot --precompile..."

  # Pass the (potentially optimized) Wasm file to lind-boot
  if "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM"; then

    if [[ -f "$PYTHON_OPT_CWASM" ]]; then
      mkdir -p "$PYTHON_OUT_DIR/usr/local/bin"
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
