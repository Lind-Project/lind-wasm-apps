#!/usr/bin/env bash
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build-native"

mkdir -p "$BUILD"
cd "$BUILD"

"$SRC/configure" --prefix="$BUILD/install"
make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu)

echo "native python: $BUILD/python"
