#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd $SCRIPT_DIR
make clean
rm tcc.wasm
rm tcc.cwasm
rm -rf tcc_headers
rm -r $APPS_ROOT/build/tinycc
