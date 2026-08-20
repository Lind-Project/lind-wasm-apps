#!/usr/bin/env bash
set -euo pipefail
LINDFS_ROOT="$1"
APPS_BIN_DIR="$2"
APP_NAME="$3"

rsync -av "$APPS_BIN_DIR/$APP_NAME/" "$LINDFS_ROOT/"

# lind-boot --precompile emits .cwasm as 0644; lind execve ignores mode bits, but
# tools doing their own PATH search (e.g. GNU make) reject non-+x candidates with EACCES.
for dir in "$LINDFS_ROOT/bin" "$LINDFS_ROOT/usr/local/bin"; do
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -type f -exec chmod 755 {} +
  fi
done

