#!/usr/bin/env bash
# stage.sh <build|smoke> <recipe file>
# Runs one recipe stage with the helpers from common.sh. Called by assess.py.
set -euo pipefail
stage="$1" recipe="$2"
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
source "$recipe"
case "$stage" in
  build) cd "$SRC"; recipe_build ;;
  smoke) cd "$LIND_WASM_ROOT"; recipe_smoke ;;
  *) echo "unknown stage $stage" >&2; exit 2 ;;
esac
