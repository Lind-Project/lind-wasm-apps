#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi


LINDFS="$LIND_WASM_ROOT/lindfs"
LINDFS_TESTS="$LINDFS/tests"

# Ensure temp directory exists in the sandbox
mkdir -p "$LINDFS/tmp"

cp -r $SCRIPT_DIR/tests $LINDFS
file="$LINDFS_TESTS/test-lib.sh"
sed -i 's|"$abs_top_builddir/src/mktemp"|bin/mktemp|g' "$file"

# =========================================================
# ARGUMENT PARSING
# =========================================================
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
    find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" | sed "s|^$LINDFS_TESTS/||" | sort
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

# Determine which tests to run
TESTS_TO_RUN=()
if [[ "$TARGET_TEST" == "--all" ]]; then
    while IFS= read -r t; do
        TESTS_TO_RUN+=("$t")
    done < <(find "$LINDFS_TESTS" -type f -executable ! -name "*.pm" ! -name "*.mk" ! -name "*.pl" | sed "s|^$LINDFS_TESTS/||" | sort)
else
    TESTS_TO_RUN=("$TARGET_TEST")
fi

# Set Sandbox Environment Variables
BUILT_PROGS=$(ls "$LINDFS/bin" | tr "\n" " ")
export built_programs="$BUILT_PROGS"
export CONFIG_HEADER="/lib/config.h"
export TMPDIR="/tmp"
export abs_top_builddir="/"
export abs_top_srcdir="/"
export PATH="/bin:/usr/local/bin:/usr/bin"
export srcdir="/tests"
export srcdir="/home/lind/lind-wasm/lindfs/tests"

# Tracking variables for the summary
TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0

# Loop through our target(s)
for CURRENT_TEST in "${TESTS_TO_RUN[@]}"; do
    HOST_TEST_PATH="$LINDFS_TESTS/$CURRENT_TEST"

    if [[ ! -f "$HOST_TEST_PATH" ]]; then
        echo "Error: Test '$CURRENT_TEST' not found in sandbox at $HOST_TEST_PATH"
        continue
    fi

    SANDBOX_PATH="/tests/$CURRENT_TEST"

    # Check shebang to dispatch to bash or perl
    read -r first_line < "$HOST_TEST_PATH" || true

    if [[ "$first_line" == *"#!/usr/bin/perl"* ]]; then
        if [[ "$SKIP_PERL" -eq 1 ]]; then
            printf "[\033[33mSKIP\033[0m] %s (Perl test skipped via flag)\n" "$CURRENT_TEST"
            ((TOTAL_SKIP++)) || true
            continue
        fi
        
        T_BASE=$(basename "$CURRENT_TEST")
        CMD=(lind_run usr/local/bin/perl -w -I/tests -MCoreutils -M"CuTmpdir qw($T_BASE)" -- "$SANDBOX_PATH")
    else
        if [[ "$SKIP_BASH" -eq 1 ]]; then
            printf "[\033[33mSKIP\033[0m] %s (Bash test skipped via flag)\n" "$CURRENT_TEST"
            ((TOTAL_SKIP++)) || true
            continue
        fi

        sed -i 's/$srcdir/tests/g' "$HOST_TEST_PATH"
        CMD=(lind-wasm bin/bash "$SANDBOX_PATH")
    fi

    echo "==================================================="
    echo "Executing: $CURRENT_TEST"
    echo "Sandbox Path: $SANDBOX_PATH"
    echo "==================================================="

    set +e
    "${CMD[@]}"
    EXIT_CODE=$?
    set -e

    echo "==================================================="
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        printf "Result: [\033[32mPASS\033[0m] (Exit 0)\n"
        ((TOTAL_PASS++)) || true
    elif [[ "$EXIT_CODE" -eq 77 ]]; then
        printf "Result: [\033[33mSKIP\033[0m] (Exit 77)\n"
        ((TOTAL_SKIP++)) || true
    else
        printf "Result: [\033[31mFAIL\033[0m] (Exit %d)\n" "$EXIT_CODE"
        ((TOTAL_FAIL++)) || true
    fi
done

# Print the final tally if running the whole suite
if [[ "$TARGET_TEST" == "--all" ]]; then
    echo "==================================================="
    echo "                  TEST SUMMARY                     "
    echo "==================================================="
    printf " [\033[32mPASS\033[0m] : %d\n" "$TOTAL_PASS"
    printf " [\033[31mFAIL\033[0m] : %d\n" "$TOTAL_FAIL"
    printf " [\033[33mSKIP\033[0m] : %d\n" "$TOTAL_SKIP"
    echo "==================================================="
fi

if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
