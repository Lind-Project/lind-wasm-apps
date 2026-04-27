#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Run the coreutils built-in test suite through the Lind runtime.
#
# Strategy:
#   1. Create wrapper scripts in a temp bin/ directory for each coreutils
#      binary. Each wrapper calls lind-wasm to execute the .cwasm binary.
#   2. Set PATH so the wrappers are found by the test harness.
#   3. Run `make check` from the coreutils source tree with the host's
#      perl/bash/awk but routing actual coreutils commands through Lind.
#
# Prerequisites:
#   - coreutils must be built: make coreutils
#   - coreutils must be installed: make install-coreutils
#   - bash, perl must be available on the host (for test harness)
#   - LIND_WASM_ROOT must point to lind-wasm installation
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
COREUTILS_ROOT="$APPS_ROOT/coreutils"
COREUTILS_BUILD="$APPS_ROOT/build/coreutils/bin"
LIND_RUN="$LIND_WASM_ROOT/scripts/lind-wasm"

# Verify prerequisites
if [[ ! -d "$COREUTILS_BUILD" ]]; then
  echo "[coreutils-test] ERROR: coreutils build dir not found at $COREUTILS_BUILD" >&2
  echo "[coreutils-test] Run 'make coreutils' first." >&2
  exit 1
fi

if [[ ! -f "$COREUTILS_ROOT/Makefile" ]]; then
  echo "[coreutils-test] ERROR: coreutils Makefile not found. Build coreutils first." >&2
  exit 1
fi

# Create wrapper directory with scripts that route through lind-wasm
WRAPPER_DIR="$(mktemp -d)"
trap 'rm -rf "$WRAPPER_DIR"' EXIT INT TERM

echo "[coreutils-test] creating lind-wasm wrapper scripts in $WRAPPER_DIR..."

# Generate a wrapper for each installed coreutils binary
for bin in "$COREUTILS_BUILD"/*; do
  [[ -f "$bin" ]] || continue
  name="$(basename "$bin")"

  # Skip non-binary files (like .wasm intermediates)
  [[ "$name" == *.wasm ]] && continue
  [[ "$name" == *.cwasm ]] && continue
  [[ "$name" == *.opt.* ]] && continue

  cat > "$WRAPPER_DIR/$name" <<WRAPPER
#!/bin/sh
exec $LIND_RUN "bin/$name" "\$@"
WRAPPER
  chmod +x "$WRAPPER_DIR/$name"
done

wrapper_count=$(ls "$WRAPPER_DIR" | wc -l)
echo "[coreutils-test] created $wrapper_count wrappers"

# Also need common tools available — link host versions if not already there
for tool in bash sh perl awk sed grep env cat echo printf test true false expr; do
  if [[ ! -f "$WRAPPER_DIR/$tool" ]] && command -v "$tool" >/dev/null 2>&1; then
    ln -sf "$(command -v "$tool")" "$WRAPPER_DIR/$tool"
  fi
done

# Run the test suite
echo "[coreutils-test] running make check with lind-wasm wrappers..."
echo "[coreutils-test] PATH=$WRAPPER_DIR:\$PATH"
echo

cd "$COREUTILS_ROOT"

PATH="$WRAPPER_DIR:$PATH" \
  make -C tests check \
    SHELL=/bin/bash \
    PERL="$(command -v perl)" \
    VERBOSE=yes \
    RUN_EXPENSIVE_TESTS=no \
    2>&1 | tee "$APPS_ROOT/build/coreutils-test-results.log"

exit_code=${PIPESTATUS[0]}

echo
echo "[coreutils-test] test results saved to build/coreutils-test-results.log"
exit "$exit_code"
