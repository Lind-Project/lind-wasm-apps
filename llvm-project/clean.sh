#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_BUILD="$APPS_ROOT/build"

rm -rf "$APPS_BUILD/libcxx-build"
rm -rf "$APPS_BUILD/libcxx-install"
