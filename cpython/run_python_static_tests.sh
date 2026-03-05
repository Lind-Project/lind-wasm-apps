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
fi

# This fix is because the python native build we have currently in lind-wasm-apps is having some errors with math library and hence we use a different Python version. We need to fix it either by porting cpython version to 3.14.3
if [[ ! -d "$PYTHON_SRC_DIR" ]]; then
    cd "$HOME_FOLDER"
    wget "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tar.xz"
    tar -xf "Python-$PYTHON_VERSION.tar.xz"
    cd "Python-$PYTHON_VERSION"
    ./configure
    make 
fi


# The following changes to Makefile is done to run python via lind-boot with dynamic loading rather than natively
cd $SCRIPT_DIR/build-wasm

TARGET_MAKEFILE="Makefile" 

if [[ -f "$TARGET_MAKEFILE" ]]; then
    sed -i \
    -e "s|../build-native/python|$PYTHON_SRC_DIR/python|g" \
    -e 's|^HOSTRUNNER=.*|HOSTRUNNER= lind-wasm|' \
    -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='lind-wasm'|" \
    "$TARGET_MAKEFILE"
else
    echo "Error: $TARGET_MAKEFILE not found in $BUILD_WASM"
    exit 1
fi


# We do this because the test script expects python.wasm within lindfs root folder. We could change it through some flags later
cp "$LINDFS_ROOT/usr/local/bin/python.cwasm" "$LINDFS_ROOT/python.wasm"
#Run tests
make test
