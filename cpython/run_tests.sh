#!/usr/bin/env bash
set -euo pipefail
set -x
###############################################################################
# CPython test suite runner for lind-wasm
#
# Respects the same BUILD_MODE and LIND_DYLINK flags used by compile_cpython.sh.
#
# linux mode:
#   The lind-run-python wrapper and HOSTRUNNER were written into
#   build-wasm/Makefile by compile_cpython.sh, so no patching is done here.
#   Just run 'make test' directly from build-wasm/.
#
# wasi mode (default):
#   Temporarily patches HOSTRUNNER in build-wasm/Makefile to lind_run and
#   restores it on exit, matching the original behavior.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
LIND_DYLINK="${LIND_DYLINK:-0}"
BUILD_MODE="${BUILD_MODE:-wasi}"
BUILD_WASM="$SCRIPT_DIR/build-wasm"

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
    echo "[cpython-test] ERROR: $LIBPYTHON_LIB not found. Run 'make install-cpython' first." >&2
    exit 1
  fi
fi

pushd "$BUILD_WASM" >/dev/null

if [[ "$BUILD_MODE" == "linux" ]]; then
  # linux mode: HOSTRUNNER was already patched into Makefile at build time.
  # Verify it is set to the generated lind-run-python wrapper.
  LIND_RUN_PYTHON="$BUILD_WASM/lind-run-python"
  if [[ ! -x "$LIND_RUN_PYTHON" ]]; then
    echo "[cpython-test] ERROR: lind-run-python not found at $LIND_RUN_PYTHON" >&2
    echo "[cpython-test]        Re-run 'BUILD_MODE=linux make cpython' to regenerate it." >&2
    exit 1
  fi

  echo "[cpython-test] running python test suite (linux mode)..."
  
  SKIP_MODULES_FILE="$SCRIPT_DIR/cpython_skip_modules.txt"
  SKIP_TESTS_FILE="$SCRIPT_DIR/cpython_skip_tests.txt"
  SKIP_MODULES_PASSED_SKIPPED="$SCRIPT_DIR/cpython_settled_modules.txt"
  SKIP_ARGS=()

  # Ensure all skip files exist (empty is fine)
  touch "$SKIP_MODULES_FILE" "$SKIP_TESTS_FILE" "$SKIP_MODULES_PASSED_SKIPPED"
  # -x args from cpython_skip_modules.txt
  if [[ -f "$SKIP_MODULES_FILE" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line%%#*}"               # strip inline comments
          line="${line//[[:space:]]/}"     # strip whitespace
          [[ -z "$line" ]] && continue
          SKIP_ARGS+=(-x "$line")
      done < "$SKIP_MODULES_FILE"
  fi
  
  # -x args from cpython_skip_modules.txt
  if [[ -f "$SKIP_MODULES_PASSED_SKIPPED" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line%%#*}"               # strip inline comments
          line="${line//[[:space:]]/}"     # strip whitespace
          [[ -z "$line" ]] && continue
          if [[ "$line" == *.* ]]; then
              SKIP_ARGS+=(-i "${line}.*")     # dotted: filter all tests under this submodule
          else
              SKIP_ARGS+=(-x "$line")          # top-level: regrtest-native exclude
          fi
      done < "$SKIP_MODULES_PASSED_SKIPPED"
  fi

  # -i args from cpython_skip_tests.txt
  if [[ -f "$SKIP_TESTS_FILE" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
          line="${line%%#*}"
          line="${line//[[:space:]]/}"
          [[ -z "$line" ]] && continue
          SKIP_ARGS+=(-i "$line")
      done < "$SKIP_TESTS_FILE"
  fi
 
  # Count of tokens (should be ~298: 4×2 + 145×2)
  #echo "count: ${#SKIP_ARGS[@]}"

  # One token per line, numbered (easiest to scan)
  #printf '%s\n' "${SKIP_ARGS[@]}" | nl

  # Joined as a single line (what python actually sees, modulo argv splitting)
  #echo "${SKIP_ARGS[*]}"
  echo "newly settled modules in this run:"
  wc -l $SKIP_MODULES_PASSED_SKIPPED
  modules=$(awk '!/^\s*(#|$)/' "$SKIP_MODULES_FILE" | wc -l)
  settled=$(awk '!/^\s*(#|$)/' "$SKIP_MODULES_PASSED_SKIPPED" | wc -l)
tests=$(awk '!/^\s*(#|$)/' "$SKIP_TESTS_FILE" | wc -l)
  #modules=$(grep -vcE '^\s*(#|$)' "$SKIP_MODULES_FILE")
  #tests=$(grep -vcE '^\s*(#|$)' "$SKIP_TESTS_FILE")
  echo "modules: $modules"
  echo "settled: $settled"
  echo "tests:   $tests"
  echo "expected tokens: $(( (modules + tests + settled) * 2 ))"

  make test "$@" TESTOPTS=" -v ${SKIP_ARGS[*]} "
else
  # wasi mode: temporarily patch HOSTRUNNER and restore on exit.
  cp Makefile Makefile.bak

  LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"

  if [[ "$LIND_DYLINK" == "1" ]]; then
    sed -i \
      -e "s|^HOSTRUNNER=.*|HOSTRUNNER= $LIND_RUN --preload env=lib/libz.so --preload env=lib/libpython3.14.so|" \
      -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='$LIND_RUN --preload env=lib/libz.so --preload env=lib/libpython3.14.so'|" \
      Makefile
  else
    sed -i \
      -e "s|^HOSTRUNNER=.*|HOSTRUNNER= $LIND_RUN|" \
      -e "s|^PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='.*'|PYTHON_FOR_BUILD=_PYTHON_HOSTRUNNER='$LIND_RUN'|" \
      Makefile
  fi

  cleanup() {
    if [[ -f "$BUILD_WASM/Makefile.bak" ]]; then
      mv "$BUILD_WASM/Makefile.bak" "$BUILD_WASM/Makefile"
    fi
  }
  trap cleanup EXIT INT TERM

  # WASI test runner expects the python binary at lindfs root as python.wasm.
  cp "$PYTHON_BINARY" "$LINDFS_ROOT/python.wasm"

  cleanup_wasm() {
    rm -f "$LINDFS_ROOT/python.wasm"
    cleanup
  }
  trap cleanup_wasm EXIT INT TERM
 
  echo "[cpython-test] running python test suite (wasi mode)..."
  make test "$@" TESTOPTS=" -v ${SKIP_ARGS}"
fi

popd >/dev/null
