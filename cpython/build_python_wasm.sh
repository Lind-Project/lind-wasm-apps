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

cd $SCRIPT_DIR

# --- Clean Target ---
if [[ "${1:-}" == "clean" ]]; then
    echo "=> Cleaning build environment..."
    
    # Clean native and wasm build
    rm -rf build-native
    rm -rf build-wasm

    # 3. Clean WASI placeholder libraries
    rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-getpid.a"
    rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-signal.a"
    rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-process-clocks.a"
    
    

    # Clean the Lind filesystem installation
    # Remove the main library and include directories
    sudo rm -rf "$LINDFS/usr/local/lib/python3.14"
    sudo rm -rf "$LINDFS/usr/local/include/python3.14"

    # Remove the static library
    sudo rm -f "$LINDFS/usr/local/lib/libpython3.14.a"

    # Remove the pkg-config files
    sudo rm -f "$LINDFS/usr/local/lib/pkgconfig/python3.pc"
    sudo rm -f "$LINDFS/usr/local/lib/pkgconfig/python-3.14-embed.pc"
    sudo rm -f "$LINDFS/usr/local/lib/pkgconfig/python3-embed.pc"
    sudo rm -f "$LINDFS/usr/local/lib/pkgconfig/python-3.14.pc"

    # Remove the manual pages
    sudo rm -f "$LINDFS/usr/local/share/man/man1/python3.1"*

    # Remove the executables
    sudo rm -f "$LINDFS/usr/local/bin/python3.14"*
    sudo rm -f "$LINDFS/usr/local/bin/python3-config"*


    
    echo "=> Clean complete."
    exit 0
fi

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

# install nescessary files into lind filesystem
sudo make install DESTDIR="${LINDFS}"

# apply wasm-opt
# /home/lind/lind-wasm/tools/binaryen/bin/wasm-opt --epoch-injection --asyncify -O2 --debuginfo python.wasm -o python.wasm
# /home/lind/lind-wasm/src/wasmtime/target/debug/wasmtime compile python.wasm -o python.cwasm

# 6. Apply wasm-opt (best-effort)
###############################################################################
PYTHON_WASM="python.wasm"

if [[ -x "$WASM_OPT" ]]; then
  echo "=> running wasm-opt (best-effort)..."
  OPT_WASM="python.opt.wasm"
  "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo \
    "$PYTHON_WASM" -o "$OPT_WASM"

  # Point the working variable to the optimized binary for the next step
  PYTHON_WASM="$OPT_WASM"
else
  echo "=> NOTE: wasm-opt not found; skipping optimization step."
fi

# 7. cwasm generation via lind-boot (best-effort)
###############################################################################
if [[ -x "$LIND_BOOT" ]]; then
  echo "=> generating cwasm via lind-boot --precompile..."

  # Pass the (potentially optimized) Wasm file to lind-boot
  if "$LIND_BOOT" --precompile "$PYTHON_WASM"; then

    # lind-boot appends .cwasm. If we passed python.opt.wasm, it made python.opt.cwasm.
    # We want to strip out the '.opt' so the final file is always python.cwasm.
    OPT_CWASM="${PYTHON_WASM%.wasm}.cwasm"
    CLEAN_CWASM="${OPT_CWASM/.opt/}"

    if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
      mv "$OPT_CWASM" "$CLEAN_CWASM"
    fi
    echo "=> Successfully generated ${CLEAN_CWASM}"

  else
    echo "=> WARNING: lind-boot --precompile failed; skipping cwasm generation."
  fi
else
  echo "=> NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
fi

echo
echo "=> Build complete. Outputs generated in current directory."
ls -lh python*.wasm python*.cwasm 2>/dev/null || true

#Copying python.cwasm to lindfs
PYTHON_CWASM="${SCRIPT_DIR}/build-wasm/python.cwasm"
if [[ -x "$PYTHON_CWASM" ]]; then
	mkdir -p ${APPS_ROOT}/build/cpython
	cp "$PYTHON_CWASM" ${APPS_ROOT}/build/cpython/usr/local/bin/python
	echo "=>Build complete. Python binary copied to build folder."
	ls -lh ${APPS_ROOT}/build/cpython/usr/local/bin/python 2>/dev/null || true
else
	echo "python.cwasm not generated. Build failed!"
fi
