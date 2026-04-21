#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"
make clean || true
rm -f tcc.wasm tcc.opt.wasm tcc.opt.cwasm libtcc1.o libtcc1.a
rm -rf tcc_headers
rm -rf "$APPS_ROOT/build/tinycc"
