#!/bin/bash
set -e # Exit immediately if a command fails

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOME_FOLDER="$(cd "$APPS_ROOT/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
BUILD_WASM="$SCRIPT_DIR/build-wasm"
SYSROOT="$LIND_WASM_ROOT/src/glibc/sysroot"
LIND_BOOT="${LIND_WASM_ROOT}/src/lind-boot/target/debug/lind-boot"
PYTHON_VERSION="3.14.3"
PYTHON_SRC_DIR="$HOME_FOLDER/Python-$PYTHON_VERSION"

# 1. Build Python WASM if Makefile doesn't exist
if [[ ! -f "$BUILD_WASM/Makefile" ]]; then
    cd "$SCRIPT_DIR"
    ./build_python_wasm.sh
    if [[ "$LIND_DYLINK" == "1" ]]; then
    	./build_shared_python_wasm.sh
    fi
fi



# The following changes to Makefile is done to run python via lind-boot with dynamic loading rather than natively
cd $SCRIPT_DIR/build-wasm

TARGET_MAKEFILE="Makefile" 

if [[ -f "$TARGET_MAKEFILE" ]]; then
    if [[ "$LIND_DYLINK" == "1" ]]; then
    sed -i \
    -e "s|^HOSTRUNNER=.*|HOSTRUNNER= lind_run --preload env=lib/libpython3.14.so|" \
    -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='lind_run --preload env=lib/libpython3.14.so'|" \
    "$TARGET_MAKEFILE"
    else
    sed -i \
    -e "s|^HOSTRUNNER=.*|HOSTRUNNER= lind_run|" \
    -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='lind_run'|" \
    "$TARGET_MAKEFILE"
	
    fi
else
    echo "Error: $TARGET_MAKEFILE not found in $BUILD_WASM"
    exit 1
fi

PYTHON_BINARY="$LINDFS_ROOT/lib/libpython3.14.so"
LIBPYTHON_LIB="$LINDFS_ROOT/usr/local/bin/python"
if [[ ! -f "$PYTHON_BINARY" ]]; then
  echo "ERROR: $PYTHON_BINARY not found. Exiting.."
  exit 1
fi

if [[ "$LIND_DYLINK" == "1" ]]; then
	if [[ ! -f "$LIBPYTHON_LIB" ]]; then
  		echo "ERROR: $LIBPYTHON_LIB not found. Exiting.."
  	        exit 1
        fi
fi

#The python test suite expects python binary to be named as python.wasm and located within root directory
cp "$PYTHON_BINARY" "$LINDFS_ROOT/python.wasm"

#Run tests
make test
rm "$LINDFS_ROOT/python.wasm"
