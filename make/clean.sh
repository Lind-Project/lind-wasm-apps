#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"
make distclean 2>/dev/null || true
rm -f *.wasm *.cwasm
rm -rf "$APPS_ROOT/build/make"
