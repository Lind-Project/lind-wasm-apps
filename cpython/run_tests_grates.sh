#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CPython test suite for lind-wasm with grates
###############################################################################

# Usage info
usage() {
  echo "Usage: $0 <grate_type> [--grate-arg <arg>] [--skip test1,test2,...]"
  echo ""
  echo "Arguments:"
  echo "  chroot    Use the chroot grate (grates/chroot-grate.cwasm --chroot-dir /)"
  echo "  ipc       Use the IPC grate (grates/ipc-grate.cwasm)"
  echo "  witness   Use the witness grate"
  echo "  fs-routing-clamp Use the fsrouting with imfs grate (requires --grate-arg)"
  echo ""
  echo "Options:"
  echo "  --grate-arg   Extra argument passed to the grate (required for fs-routing-clamp). Need to be passed with double quotes"
  echo "  --skip    Comma-separated list of test modules to skip"
  echo ""
  echo "Examples:"
  echo "  $0 chroot"
  echo "  $0 ipc"
  echo "  $0 fs-routing-clamp --grate-arg "--prefix workspace %{ grates/imfs-grate.cwasm %}" --skip test_socket"
  echo "  $0 ipc --skip test_decimal,test_math"
  echo "  $0 chroot --skip test_socket,test_ssl,test_hashlib"
  exit 1
}

# Check argument is provided
if [[ $# -eq 0 ]]; then
  echo "Error: No argument provided."
  echo ""
  usage
fi

GRATE_TYPE="$1"
GRATE_ARG=""
SKIP_LIST=""
shift

# Parse remaining options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --skip requires a value."
        echo ""
        usage
      fi
      SKIP_LIST="$2"
      shift 2
      ;;
    --grate-arg)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --grate-arg requires a value."
        echo ""
        usage
      fi
      GRATE_ARG="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown option '$1'."
      echo ""
      usage
      ;;
  esac
done



# Set GRATE_CMD based on argument
case "$GRATE_TYPE" in
  chroot)
    GRATE_CMD="grates/chroot-grate.cwasm --chroot-dir /"
    ;;
  ipc)
    GRATE_CMD="grates/ipc-grate.cwasm"
    ;;
  witness)
    GRATE_CMD="grates/witness-grate.cwasm"
    ;;
  fs-routing-clamp)
    if [[ -z "$GRATE_ARG" ]]; then
      echo "Error: grate type 'fs-routing-clamp' requires --grate-arg <argument>."
      echo ""
      usage
    fi
    GRATE_CMD="grates/fs-routing-clamp.cwasm ${GRATE_ARG}"
    ;;
  *)
    echo "Error: Unknown argument '$1'."
    echo ""
    usage
    ;;
esac

# Build the skip substring
SKIP_ARGS=""
if [[ -n "$SKIP_LIST" ]]; then
  IFS=',' read -ra SKIP_TESTS <<< "$SKIP_LIST"
  for test in "${SKIP_TESTS[@]}"; do
    SKIP_ARGS="$SKIP_ARGS -i ${test}"
  done
  SKIP_ARGS="${SKIP_ARGS# }"  # trim leading space
  echo "Skipping tests: $SKIP_ARGS"
fi

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

make test TESTOPTS="${SKIP_ARGS} --timeout=120"
popd >/dev/null
