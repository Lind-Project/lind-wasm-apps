#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
( cd "$SCRIPT_DIR/in-toto-cli" && cargo clean 2>/dev/null || true )
rm -rf "$APPS_ROOT/build/in-toto"
