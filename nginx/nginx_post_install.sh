#!/usr/bin/env bash
set -euo pipefail

LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"

mkdir -p "$LINDFS_ROOT/bin" "$LINDFS_ROOT/etc/nginx" "$LINDFS_ROOT/html" \
         "$LINDFS_ROOT/var/log/nginx" "$LINDFS_ROOT/var/run"
cp "$APPS_BIN_DIR/nginx/wasm32-wasi/nginx.cwasm" "$LINDFS_ROOT/bin/nginx"
cp -r "$APPS_BIN_DIR/nginx/wasm32-wasi/conf/." "$LINDFS_ROOT/etc/nginx/"
cp -r "$APPS_BIN_DIR/nginx/wasm32-wasi/html/." "$LINDFS_ROOT/html/"
