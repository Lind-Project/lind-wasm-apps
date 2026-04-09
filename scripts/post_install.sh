#!/usr/bin/env bash
set -euo pipefail
LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"
APP_NAME="$3"
rsync -av "$APPS_BIN_DIR/$APP_NAME/" "$LINDFS_ROOT/"

# Copy CA bundle for curl HTTPS support
if [[ "$APP_NAME" == "curl" ]]; then
    mkdir -p "$LINDFS_ROOT/etc/ssl/certs"
    cp /etc/ssl/certs/ca-certificates.crt "$LINDFS_ROOT/etc/ssl/certs/ca-certificates.crt"
fi