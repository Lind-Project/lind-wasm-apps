#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_BUILD="$APPS_ROOT/build"

rm -rf "$APPS_BUILD/gcc-build"
rm -rf "$APPS_BUILD/gcc"
rm -f "$SCRIPT_DIR/cc1.wasm" "$SCRIPT_DIR/cc1.opt.wasm" "$SCRIPT_DIR/cc1.opt.cwasm"
