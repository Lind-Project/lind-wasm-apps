#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# OpenBLAS test script for lind-wasm
#
# Usage: ./openblas/run_tests.sh
#
# Runs two independent OpenBLAS test suites under the lind-wasm runtime and
# requires every discovered test to actually pass:
#
#   - utest/ (openblas_utest, openblas_utest_ext): OpenBLAS's own C unit
#     tests, using the ctest.h framework — narrow, targeted coverage of
#     specific extension functions (omatcopy, imatcopy, geadd, gemmt) and
#     edge cases (xerbla argument-validation paths).
#   - ctest/ (xscblat1/2/3, xdcblat1/2/3): the CBLAS interface conformance
#     suite — broad, systematic Level 1/2/3 BLAS correctness sweeps through
#     the cblas_* entry points (the same interface NumPy's dot/matmul use,
#     for a concrete reason: CBLAS's row-major flag lets a C-contiguous
#     caller skip transposing before the call, which the raw Fortran ABI
#     doesn't offer). Complementary to utest/, not redundant with it.
#
# ctest/ has a Fortran-free path (OpenBLAS's own ctest/Makefile: with
# NOFORTRAN=1, each xNcblatM target links a plain-C driver instead of the
# classic .f one), which is what makes it buildable at all here. The
# separate test/ suite (the classic Fortran BLAS reference tests, as
# opposed to this CBLAS one) has no such fallback — its own 'all' target
# is an unconditional no-op under NOFORTRAN=1 — and is out of scope; no
# wasm32 Fortran compiler exists. See compile_openblas.sh for both.
#
# compile_openblas.sh patches around a real wasm-ld incompatibility in
# utest/'s test harness (utest/ctest.h): its default test auto-discovery
# relies on a linker-section scan that wasm-ld does not support, which used
# to make both utest binaries report "0 tests ran" — silently skipping
# every assertion. The patched build registers tests explicitly instead,
# verified to find and pass the exact same test counts as a native x86_64
# build of this source with matching flags: 68 tests (openblas_utest) and
# 607 tests (openblas_utest_ext). ctest/'s binaries need no such patch —
# they're plain main() programs, not ctest.h-based — verified against that
# same native baseline: 11/49/19 PASS lines (xscblat1/2/3) and the same
# 11/49/19 (xdcblat1/2/3), 0 FAIL/FATAL, in both dylink and static mode.
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
  echo "[openblas] testing DYNAMIC build (libopenblas.so found in lindfs, will be preloaded)"
else
  echo "[openblas] testing STATIC build (no libopenblas.so in lindfs; test binaries are statically linked)"
fi

CTEST_SRC_DIR="$APPS_ROOT/openblas/ctest"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

check_binary_installed() {
  local bin="$1"
  local bin_path="/usr/local/bin/$bin"

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
}

run_utest_binary() {
  local bin="$1"
  local bin_path="/usr/local/bin/$bin"

  echo
  check_binary_installed "$bin"

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

# ctest/'s C drivers are plain main() programs, not ctest.h-based, so they
# have no clean machine-parseable summary line — just the classic BLAS
# reference-suite text ("<routine> PASSED THE ... TESTS" / "FAILED ON CALL
# NUMBER" / "FATAL ERROR"). Follow OpenBLAS's own native build's convention
# for recognizing failure here (its Makefile greps test logs for FATAL or
# FAILED), and additionally require at least one PASS line, so a crash that
# produces no output at all doesn't silently read as success.
run_ctest_binary() {
  local bin="$1" input_file="${2:-}"

  echo
  check_binary_installed "$bin"

  echo "[test] Running $bin under lind-wasm..."
  local output
  if [[ -n "$input_file" ]]; then
    output=$(sudo "$LIND_RUN" "${PRELOAD_ARGS[@]}" "/usr/local/bin/$bin" < "$input_file" 2>&1) || true
  else
    output=$(sudo "$LIND_RUN" "${PRELOAD_ARGS[@]}" "/usr/local/bin/$bin" 2>&1) || true
  fi

  echo "$output" | tail -5 | sed 's/^/    /'

  local pass_count
  pass_count=$(echo "$output" | grep -ciE 'PASS')

  if echo "$output" | grep -qiE 'FAIL|FATAL'; then
    fail "$bin" "ctest reported a failure, see output above"
  elif [[ "$pass_count" -eq 0 ]]; then
    fail "$bin" "no PASS/FAIL markers at all in output — crashed or produced nothing; output: $output"
  else
    pass "$bin: $pass_count PASS line(s), 0 failures"
  fi
}

run_utest_binary openblas_utest
run_utest_binary openblas_utest_ext

run_ctest_binary xscblat1
run_ctest_binary xscblat2 "$CTEST_SRC_DIR/sin2"
run_ctest_binary xscblat3 "$CTEST_SRC_DIR/sin3"
run_ctest_binary xdcblat1
run_ctest_binary xdcblat2 "$CTEST_SRC_DIR/din2"
run_ctest_binary xdcblat3 "$CTEST_SRC_DIR/din3"

echo
echo "=========================================="
echo "openblas tests: $PASS passed, $FAIL failed"
echo "=========================================="

[[ $FAIL -eq 0 ]]
