#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

rm -rf "$SCRIPT_DIR/build-native"
rm -rf "$SCRIPT_DIR/build-wasm"
rm -rf "$APPS_ROOT/build/cpython"

# Clean WASI placeholder libraries from overlay
rm -f "$APPS_ROOT/build/sysroot_overlay/usr/lib/wasm32-wasi/libwasi-emulated-getpid.a"
rm -f "$APPS_ROOT/build/sysroot_overlay/usr/lib/wasm32-wasi/libwasi-emulated-signal.a"
rm -f "$APPS_ROOT/build/sysroot_overlay/usr/lib/wasm32-wasi/libwasi-emulated-process-clocks.a"
