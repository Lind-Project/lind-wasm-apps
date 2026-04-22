#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAY="$REPO_ROOT/build/sysroot_overlay/"
LINDFS_ROOT="$1"
LIB="$2"
mkdir -p "$LINDFS_ROOT/lib"

if [[ "$LIB" == "libtirpc" ]]; then
    cp "$OVERLAY/lib/libtirpc.so" "$LINDFS_ROOT/lib"
elif [[ "$LIB" == "openssl" ]]; then
    cp "$OVERLAY/lib/libssl.so" "$LINDFS_ROOT/lib"
    cp "$OVERLAY/lib/libcrypto.so" "$LINDFS_ROOT/lib"
elif [[ "$LIB" == "gnulib" ]]; then
    cp "$OVERLAY/lib/libgnu.so" "$LINDFS_ROOT/lib"
elif [[ "$LIB" == "zlib" ]]; then
    cp "$OVERLAY/lib/libz.so" "$LINDFS_ROOT/lib"
fi

