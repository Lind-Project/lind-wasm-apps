#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$SCRIPT_DIR"
make clean >/dev/null 2>&1 || true
rm -f Makefile.conf config.h getarch getarch_2nd
rm -f utest/*.opt.wasm utest/*.opt.cwasm
rm -f utest/test_registry.c utest/test_extensions/test_registry_ext.c
rm -rf "$APPS_ROOT/build/openblas"
