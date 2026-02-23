#!/usr/bin/env bash
set -euo pipefail

LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"

mkdir -p "$LINDFS_ROOT/bin"
cp "$APPS_BIN_DIR/bash/wasm32-wasi/bash.cwasm" "$LINDFS_ROOT/bin/bash"
