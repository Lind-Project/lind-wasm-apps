#!/usr/bin/env bash
set -euo pipefail

# Build a native host python — required as --with-build-python for cross-compiling.

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SRC/build-native"

if [[ -f "$BUILD/python" ]]; then
  echo "[cpython] native python already built: $BUILD/python"
  exit 0
fi

mkdir -p "$BUILD"
pushd "$BUILD" >/dev/null

"$SRC/configure" --prefix="$BUILD/install"
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu || echo 4)"

popd >/dev/null
echo "[cpython] native python: $BUILD/python"
