#!/usr/bin/env bash
set -euo pipefail

# Install dynamically-built shared libraries (.so) from the sysroot overlay
# into lindfs. Only copies files that exist — no-ops gracefully for static builds.
#
# Usage: post_install_lib.sh <lindfs_root> <lib_name>

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY="$REPO_ROOT/build/sysroot_overlay"
LINDFS_ROOT="$1"
LIB="$2"

# Determine which .so files to install
case "$LIB" in
  libtirpc) SO_FILES=(libtirpc.so) ;;
  openssl)  SO_FILES=(libssl.so libcrypto.so) ;;
  gnulib)   SO_FILES=(libgnu.so) ;;
  zlib)     SO_FILES=(libz.so) ;;
  *)
    echo "[install-lib] ERROR: unknown library '$LIB'" >&2
    exit 1
    ;;
esac

# Copy each .so if it exists (dynamic build produced it)
installed=0
for so in "${SO_FILES[@]}"; do
  src="$OVERLAY/lib/$so"
  if [[ -f "$src" ]]; then
    mkdir -p "$LINDFS_ROOT/lib"
    cp "$src" "$LINDFS_ROOT/lib/"
    echo "[install-lib] $so -> $LINDFS_ROOT/lib/"
    (( installed++ )) || true
  fi
done

if (( installed == 0 )); then
  echo "[install-lib] NOTE: no .so files found for $LIB (static build only?); nothing to install."
fi
