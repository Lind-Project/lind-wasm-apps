#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CPython test suite for lind-wasm with grates
###############################################################################

# Usage info
usage() {
  echo "Usage: $0 <grate_type>"
  echo ""
  echo "Arguments:"
  echo "  chroot    Use the chroot grate (grates/chroot-grate.cwasm --chroot-dir /)"
  echo "  ipc       Use the IPC grate (grates/ipc-grate.cwasm)"
  echo "  witness   Use the witness grate"
  echo "  fsrouting Use the fsrouting with imfs grate"
  echo ""
  echo "Examples:"
  echo "  $0 chroot"
  echo "  $0 ipc"
  exit 1
}

# Check argument is provided
if [[ -z "${1:-}" ]]; then
  echo "Error: No argument provided."
  echo ""
  usage
fi

# Set GRATE_CMD based on argument
case "$1" in
  chroot)
    GRATE_CMD="grates/chroot-grate.cwasm --chroot-dir /"
    ;;
  ipc)
    GRATE_CMD="grates/ipc-grate.cwasm"
    ;;
  *)
    echo "Error: Unknown argument '$1'."
    echo ""
    usage
    ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
LIND_DYLINK="${LIND_DYLINK:-0}"
BUILD_WASM="$SCRIPT_DIR/build-wasm"

LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"

# --- verify build exists -----------------------------------------------------
if [[ ! -f "$BUILD_WASM/Makefile" ]]; then
  echo "[cpython-test] ERROR: $BUILD_WASM/Makefile not found. Run 'make cpython' first." >&2
  exit 1
fi

PYTHON_BINARY="$LINDFS_ROOT/usr/local/bin/python"
if [[ ! -f "$PYTHON_BINARY" ]]; then
  echo "[cpython-test] ERROR: $PYTHON_BINARY not found. Run 'make install-cpython' first." >&2
  exit 1
fi

if [[ "$LIND_DYLINK" == "1" ]]; then
  LIBPYTHON_LIB="$LINDFS_ROOT/lib/libpython3.14.so"
  if [[ ! -f "$LIBPYTHON_LIB" ]]; then
    echo "[cpython-test] ERROR: $LIBPYTHON_LIB not found." >&2
    exit 1
  fi
fi

# --- patch Makefile HOSTRUNNER to use lind_run --------------------------------
# Use a backup so we can restore on cleanup.
pushd "$BUILD_WASM" >/dev/null

cp Makefile Makefile.bak

if [[ "$LIND_DYLINK" == "1" ]]; then
  sed -i \
    -e "s|^HOSTRUNNER=.*|HOSTRUNNER= lind_run --preload env=lib/libz.so --preload env=lib/libpython3.14.so ${GRATE_CMD}|" \
    -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='lind_run --preload env=lib/libz.so --preload env=lib/libpython3.14.so ${GRATE_CMD}'|" \
    Makefile
else
  sed -i \
    -e "s|^HOSTRUNNER=.*|HOSTRUNNER= lind_run ${GRATE_CMD}|" \
    -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='lind_run ${GRATE_CMD}'|" \
    Makefile
fi

# --- cleanup trap -------------------------------------------------------------
cleanup() {
  rm -f "$LINDFS_ROOT/python.wasm"
  if [[ -f "$BUILD_WASM/Makefile.bak" ]]; then
    mv "$BUILD_WASM/Makefile.bak" "$BUILD_WASM/Makefile"
  fi
}
trap cleanup EXIT INT TERM

# The python test suite expects python binary to be named python.wasm at root
cp "$PYTHON_BINARY" "$LINDFS_ROOT/python.wasm"

# --- run tests ----------------------------------------------------------------
echo "[cpython-test] running python test suite..."
make test

popd >/dev/null
