#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# OpenBLAS test script for lind-wasm
#
# Usage: ./openblas/run_tests.sh
#
# Runs OpenBLAS's own utest/ suite (openblas_utest, openblas_utest_ext) under
# the lind-wasm runtime and requires every discovered test to actually pass.
#
# compile_openblas.sh patches around a real wasm-ld incompatibility in
# OpenBLAS's upstream test harness (utest/ctest.h): its default test
# auto-discovery relies on a linker-section scan that wasm-ld does not
# support, which used to make both binaries report "0 tests ran" — silently
# skipping every assertion. The patched build registers tests explicitly
# instead, verified to find and pass the exact same test counts as a native
# x86_64 build of this source with matching flags: 66 tests (openblas_utest)
# and 600 tests (openblas_utest_ext). See compile_openblas.sh for details.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$APPS_ROOT/.." && pwd)}"
STAGE_DIR="$APPS_ROOT/build/openblas/usr/local/bin"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

run_utest_binary() {
  local bin="$1"
  local bin_path="/usr/local/bin/$bin"

  echo
  echo "[test] Checking staged binary ($bin)..."
  if [[ ! -f "$STAGE_DIR/$bin" ]]; then
    echo "  ERROR: $bin not found at $STAGE_DIR/$bin"
    echo "  Please build openblas first by running:"
    echo "    make openblas"
    exit 1
  fi
  echo "  OK: staged binary found at $STAGE_DIR/$bin"

  echo "[test] Checking lindfs installation ($bin)..."
  if [[ ! -f "$LINDFS_ROOT$bin_path" ]]; then
    echo "  ERROR: $bin is not installed in lindfs ($LINDFS_ROOT$bin_path not found)"
    echo "  Please build and install openblas by running:"
    echo "    make openblas"
    echo "    make install-openblas"
    exit 1
  fi
  echo "  OK: $bin installed at $LINDFS_ROOT$bin_path"

  echo "[test] Running $bin under lind-wasm..."
  local output
  if output=$(sudo "$LIND_RUN" "$bin_path" 2>&1); then
    :
  else
    fail "$bin execution" "runtime exited non-zero; output: $output"
    return
  fi

  echo "$output" | tail -5 | sed 's/^/    /'

  local results_line
  results_line=$(echo "$output" | grep '^RESULTS:' || true)
  if [[ -z "$results_line" ]]; then
    fail "$bin execution" "no RESULTS summary line in output"
    return
  fi

  # "RESULTS: N tests (N ok, F failed, S skipped) ran in T ms"
  local total ok failed
  total=$(echo "$results_line" | sed -E 's/RESULTS: ([0-9]+) tests.*/\1/')
  ok=$(echo "$results_line" | sed -E 's/.*\(([0-9]+) ok.*/\1/')
  failed=$(echo "$results_line" | sed -E 's/.*, ([0-9]+) failed.*/\1/')

  if [[ "$total" -eq 0 ]]; then
    fail "$bin" "discovered 0 tests ($results_line) — test registration is broken, see compile_openblas.sh"
  elif [[ "$failed" -gt 0 ]]; then
    fail "$bin" "$failed/$total tests failed ($results_line)"
  else
    pass "$bin: $ok/$total tests passed ($results_line)"
  fi
}

run_utest_binary openblas_utest
run_utest_binary openblas_utest_ext

echo
echo "=========================================="
echo "openblas tests: $PASS passed, $FAIL failed"
echo "=========================================="

[[ $FAIL -eq 0 ]]
