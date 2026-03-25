#!/usr/bin/env bash
set -euo pipefail

LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"
APP_NAME="$3"

rsync -av "$APPS_BIN_DIR/$APP_NAME/" "$LINDFS_ROOT/"
