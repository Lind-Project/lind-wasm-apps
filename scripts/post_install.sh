#!/usr/bin/env bash
set -euo pipefail

LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"
APP_NAME="$3"

mkdir -p "$LINDFS_ROOT/bin"
for f in "$APPS_BIN_DIR/$APP_NAME/wasm32-wasi/"*.cwasm; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .cwasm)"
  cp "$f" "$LINDFS_ROOT/bin/$base"
done
