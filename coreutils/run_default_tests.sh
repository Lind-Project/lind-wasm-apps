#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Run the coreutils built-in test suite through the Lind runtime.
#
# The coreutils tests are a mix of bash and perl scripts that invoke
# coreutils binaries by name. We copy the tests into lindfs, set up the
# environment, and dispatch each test through lind-wasm.
#
# Prerequisites:
#   - coreutils built and installed: make coreutils && make install-coreutils
#   - bash, perl, awk, grep, sed, diffutils installed in lindfs
#   - LIND_WASM_ROOT set or defaulting to ~/lind-wasm
#
# Usage:
#   ./run_default_tests.sh --all              # run all tests
#   ./run_default_tests.sh --all --skip-bash  # skip bash tests
#   ./run_default_tests.sh --all --skip-perl  # skip perl tests
#   ./run_default_tests.sh --list             # list available tests
#   ./run_default_tests.sh misc/basename      # run specific test
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS="$LIND_WASM_ROOT/lindfs"
LINDFS_TESTS="$LINDFS/tests"
RESULTS_LOG="$APPS_ROOT/build/coreutils-lind-results.log"

mkdir -p "$LINDFS/tmp" "$APPS_ROOT/build"

# --- Copy tests into lindfs ---------------------------------------------------

echo "[coreutils-test] copying test suite to lindfs..."
cp -r "$SCRIPT_DIR/tests" "$LINDFS/"

# Patch test-lib.sh to use sandbox paths
if [[ -f "$LINDFS_TESTS/test-lib.sh" ]]; then
  sed -i 's|"$abs_top_builddir/src/mktemp"|bin/mktemp|g' "$LINDFS_TESTS/test-lib.sh"
fi

# Copy pr test data if present
if [[ -d "$SCRIPT_DIR/tests/pr" ]]; then
  cp -r "$SCRIPT_DIR/tests/pr" "$LINDFS_TESTS/"
fi

# --- Argument parsing ---------------------------------------------------------

SKIP_BASH=0
SKIP_PERL=0
TARGET_TEST=""

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --list) TARGET_TEST="--list"; shift ;;
    --all) TARGET_TEST="--all"; shift ;;
    --skip-bash) SKIP_BASH=1; shift ;;
    --skip-perl) SKIP_PERL=1; shift ;;
    *) TARGET_TEST="$1"; shift ;;
  esac
done

if [[ "$TARGET_TEST" == "--list" ]]; then
  echo "Available Tests:"
  echo "---------------------------------------------------"
  find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" ! -name "*.sh" \
    | sed "s|^$LINDFS_TESTS/||" | sort
  exit 0
fi

if [[ -z "$TARGET_TEST" ]]; then
  echo "Usage:"
  echo "  $0 --list                 # Print all available tests"
  echo "  $0 --all                  # Run all tests"
  echo "  $0 misc/help-version      # Run a specific test"
  echo "  Options:"
  echo "    --skip-bash             # Skip all Bash tests"
  echo "    --skip-perl             # Skip all Perl tests"
  exit 1
fi

# --- Determine which tests to run ---------------------------------------------

TESTS_TO_RUN=()
if [[ "$TARGET_TEST" == "--all" ]]; then
  while IFS= read -r t; do
    TESTS_TO_RUN+=("$t")
  done < <(find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" ! -name "*.sh" \
    | sed "s|^$LINDFS_TESTS/||" | sort)
else
  TESTS_TO_RUN=("$TARGET_TEST")
fi

# --- Set sandbox environment variables ----------------------------------------
# These are passed to the test scripts inside the sandbox.

BUILT_PROGS=$(ls "$LINDFS/bin" 2>/dev/null | tr "\n" " ")

# Tracking variables
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

# --- Run tests ----------------------------------------------------------------

for CURRENT_TEST in "${TESTS_TO_RUN[@]}"; do
  HOST_TEST_PATH="$LINDFS_TESTS/$CURRENT_TEST"

  if [[ ! -f "$HOST_TEST_PATH" ]]; then
    echo "Error: Test '$CURRENT_TEST' not found at $HOST_TEST_PATH"
    continue
  fi

  SANDBOX_PATH="/tests/$CURRENT_TEST"

  # Check shebang to dispatch to bash or perl
  read -r first_line < "$HOST_TEST_PATH" || true

  if [[ "$first_line" == *"#!/usr/bin/perl"* ]]; then
    if [[ "$SKIP_PERL" -eq 1 ]]; then
      printf "[\033[33mSKIP\033[0m] %s (Perl test skipped)\n" "$CURRENT_TEST"
      ((TOTAL_SKIP++)) || true
      continue
    fi

    T_BASE=$(basename "$CURRENT_TEST")
    CMD=(lind-wasm --enable-fpcast \
      --env "built_programs=$BUILT_PROGS" \
      --env "srcdir=/tests" \
      --env "abs_top_builddir=/" \
      --env "abs_top_srcdir=/" \
      --env "abs_srcdir=/tests" \
      --env "CONFIG_HEADER=/lib/config.h" \
      --env "TMPDIR=/tmp" \
      --env "PATH=/bin:/usr/local/bin" \
      usr/local/bin/perl -w \
      -I/lib/perl5/5.40.4 \
      -I/tests \
      -MCoreutils \
      -M"CuTmpdir qw($T_BASE)" \
      -- "$SANDBOX_PATH")
  else
    if [[ "$SKIP_BASH" -eq 1 ]]; then
      printf "[\033[33mSKIP\033[0m] %s (Bash test skipped)\n" "$CURRENT_TEST"
      ((TOTAL_SKIP++)) || true
      continue
    fi

    CMD=(lind-wasm --enable-fpcast \
      --env "built_programs=$BUILT_PROGS" \
      --env "srcdir=/tests" \
      --env "abs_top_builddir=/" \
      --env "abs_top_srcdir=/" \
      --env "abs_srcdir=/tests" \
      --env "CONFIG_HEADER=/lib/config.h" \
      --env "TMPDIR=/tmp" \
      --env "PATH=/bin:/usr/local/bin" \
      bin/bash "$SANDBOX_PATH")
  fi

  echo "==================================================="
  echo "Executing: $CURRENT_TEST"
  echo "==================================================="

  set +e
  "${CMD[@]}"
  EXIT_CODE=$?
  set -e

  if [[ "$EXIT_CODE" -eq 0 ]]; then
    printf "[\033[32mPASS\033[0m] %s\n" "$CURRENT_TEST"
    ((TOTAL_PASS++)) || true
  elif [[ "$EXIT_CODE" -eq 77 ]]; then
    printf "[\033[33mSKIP\033[0m] %s (exit 77)\n" "$CURRENT_TEST"
    ((TOTAL_SKIP++)) || true
  else
    printf "[\033[31mFAIL\033[0m] %s (exit %d)\n" "$CURRENT_TEST" "$EXIT_CODE"
    ((TOTAL_FAIL++)) || true
  fi
done

# --- Summary ------------------------------------------------------------------

echo
echo "==================================================="
echo "              COREUTILS TEST SUMMARY"
echo "==================================================="
printf " [\033[32mPASS\033[0m] : %d\n" "$TOTAL_PASS"
printf " [\033[31mFAIL\033[0m] : %d\n" "$TOTAL_FAIL"
printf " [\033[33mSKIP\033[0m] : %d\n" "$TOTAL_SKIP"
echo " TOTAL : $(( TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP ))"
echo "==================================================="

# Save results
{
  echo "PASS: $TOTAL_PASS"
  echo "FAIL: $TOTAL_FAIL"
  echo "SKIP: $TOTAL_SKIP"
  echo "TOTAL: $(( TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP ))"
} > "$RESULTS_LOG"
echo "Results saved to: $RESULTS_LOG"

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  exit 1
else
  exit 0
fi
