#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGE_DIR="$APPS_ROOT/build/cpython"

# Clean native and wasm build
rm -rf $SCRIPT_DIR/build-native
rm -rf $SCRIPT_DIR/build-wasm

# 3. Clean WASI placeholder libraries
rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-getpid.a"
rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-signal.a"
rm -f "${SYSROOT}/lib/wasm32-wasi/libwasi-emulated-process-clocks.a"


# Clean the Lind filesystem installation
sudo rm -rf "$STAGE_DIR"

