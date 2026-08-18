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
# x86_64 build of this source with matching flags: 68 tests (openblas_utest)
# and 607 tests (openblas_utest_ext). See compile_openblas.sh for details.
#
# LIND_DYLINK=1 (default) is the primary configuration: the test binaries
# import their BLAS/CBLAS symbols at runtime from libopenblas.so, so this
# script preloads it — the tests genuinely exercise the .so, not a separate
# statically-linked copy of the same code. LIND_DYLINK=0 is the legacy
# static-only fallback, which needs no preload.
#
# As of OpenBLAS 0.3.34, all tests pass cleanly in both modes. Earlier
# versions' utest_ext suite had ~100 tests that overrode BLAS's xerbla_
# error hook by defining their own BLASFUNC(xerbla) symbol, relying on
# cross-module symbol interposition that lind-wasm's dylink loader does
# not support (preloads are fully resolved before main exists). 0.3.34
# added openblas_set_xerbla(), a runtime callback-registration API, and
# switched the test harness to use it — a normal function call, not
# symbol interposition — which sidesteps the limitation entirely. See
# /home/lind/lind-wasm/issue-dylink-symbol-interposition.md for background
# on the underlying (still-present) loader limitation itself.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$APPS_ROOT/.." && pwd)}"
STAGE_DIR="$APPS_ROOT/build/openblas/usr/local/bin"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run"

PRELOAD_ARGS=()
if [[ -f "$LINDFS_ROOT/lib/libopenblas.so" ]]; then
  PRELOAD_ARGS=(--preload env=lib/libopenblas.so)
fi

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
  # ctest.h's own convention is to exit with the failed-test count, so a
  # nonzero exit here is not by itself an execution failure. Only the
  # absence of a RESULTS line (crash before ctest_main finished) is.
  local output
  output=$(sudo "$LIND_RUN" "${PRELOAD_ARGS[@]}" "$bin_path" 2>&1) || true

  echo "$output" | tail -5 | sed 's/^/    /'

  local results_line
  results_line=$(echo "$output" | grep '^RESULTS:' || true)
  if [[ -z "$results_line" ]]; then
    fail "$bin execution" "no RESULTS summary line in output; output: $output"
    return
  fi

  # "RESULTS: N tests (N ok, F failed, S skipped) ran in T ms"
  local total failed
  total=$(echo "$results_line" | sed -E 's/RESULTS: ([0-9]+) tests.*/\1/')
  failed=$(echo "$results_line" | sed -E 's/.*, ([0-9]+) failed.*/\1/')

  if [[ "$total" -eq 0 ]]; then
    fail "$bin" "discovered 0 tests ($results_line) — test registration is broken, see compile_openblas.sh"
  elif [[ "$failed" -gt 0 ]]; then
    fail "$bin" "$failed/$total tests failed ($results_line)"
  else
    pass "$bin: $total/$total tests passed ($results_line)"
  fi
}

run_utest_binary openblas_utest
run_utest_binary openblas_utest_ext

echo
echo "=========================================="
echo "openblas tests: $PASS passed, $FAIL failed"
echo "=========================================="

[[ $FAIL -eq 0 ]]
