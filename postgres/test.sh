#!/bin/bash
set -uo pipefail

# postgres/test.sh — Smoke tests for PostgreSQL on lind-wasm
#
# Verifies that postgres and initdb binaries are installed correctly
# and can handle basic invocations (--version, --help).

LIND_WASM_ROOT="${LIND_WASM_ROOT:-/home/lind/lind-wasm}"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN="sudo $LIND_WASM_ROOT/scripts/lind_run"

cd "$LINDFS_ROOT"

echo "Starting postgres smoke tests..."

FAILS=0

check_result() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $test_name"
    else
        echo "[FAIL] $test_name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        FAILS=$((FAILS + 1))
    fi
}

# 1. Check that binaries exist in lindfs/bin
echo "--- Binary installation checks ---"

if [ -f bin/postgres ]; then
    echo "[PASS] postgres binary exists at bin/postgres"
else
    echo "[FAIL] postgres binary not found at bin/postgres"
    FAILS=$((FAILS + 1))
fi

if [ -f bin/initdb ]; then
    echo "[PASS] initdb binary exists at bin/initdb"
else
    echo "[FAIL] initdb binary not found at bin/initdb"
    FAILS=$((FAILS + 1))
fi

# 2. postgres --version
echo "--- Version checks ---"

ACTUAL=$($LIND_RUN /bin/postgres --version 2>/dev/null)
check_result "postgres --version" "postgres (PostgreSQL) 19devel" "$ACTUAL"

ACTUAL=$($LIND_RUN /bin/initdb --version 2>/dev/null)
check_result "initdb --version" "initdb (PostgreSQL) 19devel" "$ACTUAL"

# 3. postgres --help (check that it produces usage output)
echo "--- Help output checks ---"

HELP_OUTPUT=$($LIND_RUN /bin/postgres --help 2>/dev/null)
if echo "$HELP_OUTPUT" | grep -q "postgres is the PostgreSQL server"; then
    echo "[PASS] postgres --help produces expected output"
else
    echo "[FAIL] postgres --help did not produce expected output"
    FAILS=$((FAILS + 1))
fi

echo "-----------------------------------"
if [ $FAILS -eq 0 ]; then
    echo "Success: All postgres smoke tests passed!"
    exit 0
else
    echo "Failure: $FAILS test(s) failed."
    exit 1
fi
