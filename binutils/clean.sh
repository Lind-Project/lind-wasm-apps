#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_BUILD="$APPS_ROOT/build"

rm -rf "$APPS_BUILD/binutils-build"
rm -rf "$APPS_BUILD/binutils"
rm -f "$SCRIPT_DIR/ld.wasm" "$SCRIPT_DIR/ld.opt.wasm" "$SCRIPT_DIR/ld.opt.cwasm"
rm -f "$SCRIPT_DIR/as.wasm" "$SCRIPT_DIR/as.opt.wasm" "$SCRIPT_DIR/as.opt.cwasm"
