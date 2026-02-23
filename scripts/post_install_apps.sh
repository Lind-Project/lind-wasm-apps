#!/usr/bin/env bash
set -euo pipefail

LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"
APP_NAME="$3"

mkdir -p "$LINDFS_ROOT/bin"
cp "$APPS_BIN_DIR/$APP_NAME/wasm32-wasi/$APP_NAME.cwasm" "$LINDFS_ROOT/bin/$APP_NAME"
