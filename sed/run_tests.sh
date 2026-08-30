#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDBOOT_BIN="$LIND_WASM_ROOT/build/lind-boot"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
STAGE_DIR="$APPS_ROOT/build/sed/usr/local/bin"
LIND_RUN_CMD="lind_run"
SED_BINARY="/usr/local/bin/sed"
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"

source "$SCRIPT_DIR/../scripts/test_lib.sh"

# --- Preconditions — must run before any test is recorded -------------------
if [[ ! -f "$STAGE_DIR/sed" ]]; then
    echo "ERROR: sed binary not found at $STAGE_DIR/sed"
    echo "Please build sed first by running:"
    echo "  make sed"
    exit 1
fi

if [[ ! -f "$LINDFS_ROOT$SED_BINARY" ]]; then
    echo "ERROR: sed is not installed in lindfs ($LINDFS_ROOT$SED_BINARY not found)"
    echo "Please build and install sed by running:"
    echo "  make sed"
    echo "  make install-sed"
    exit 1
fi

cd "$LINDFS_ROOT"
trap 'rm -f "$LINDFS_ROOT/test_inplace.txt" "$LINDFS_ROOT/script.sed"' EXIT

echo "Starting sed sandbox tests..."

PASS=0
FAILS=0
TOTAL=0

# Helper function to validate outputs
check_result() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if is_skipped "$test_name"; then
        log_skip "$test_name"
        return
    fi

    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $test_name"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        FAILS=$((FAILS + 1))
    fi
}

# 1. Basic Stream Substitution
ACTUAL=$(echo "Hello World" | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY 's/World/Sandbox/')
check_result "Basic Substitution" "Hello Sandbox" "$ACTUAL"

# 2. Global Substitution
ACTUAL=$(echo "apple banana apple" | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY 's/a[a-z]*e/orange/g')
check_result "Global Substitution" "orange banana orange" "$ACTUAL"

# 3. In-Place File Editing (-i)
# This heavily stresses file-related system calls (open, read, write, rename, unlink)
echo "Version 1.0" > test_inplace.txt
timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY -i 's/1.0/2.0/' test_inplace.txt
ACTUAL=$(cat test_inplace.txt)
check_result "In-Place Editing" "Version 2.0" "$ACTUAL"
rm -f test_inplace.txt

# 4. Line Deletion
ACTUAL=$(printf "keep me\ndelete me\nkeep me too\n" | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY '/delete/d')
EXPECTED=$(printf "keep me\nkeep me too")
check_result "Line Deletion" "$EXPECTED" "$ACTUAL"

# 5. Selective Printing (-n)
ACTUAL=$(printf "apple\nbanana\ncherry\n" | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY -n '/banana/p')
check_result "Selective Printing" "banana" "$ACTUAL"

# 6. Multiple Commands (-e)
ACTUAL=$(echo "foo and bar" | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY -e 's/foo/baz/' -e 's/bar/qux/')
check_result "Multiple Commands" "baz and qux" "$ACTUAL"

# 7. Reading Commands from a Script (-f)
echo "s/cat/dog/g" > script.sed
ACTUAL=$(echo "The cat chased the other cat." | timeout "${TIMEOUT_SECS}s" $LIND_RUN_CMD $SED_BINARY -f script.sed)
check_result "Script File" "The dog chased the other dog." "$ACTUAL"
rm -f script.sed

echo "-----------------------------------"
echo "Results: $TOTAL total, $PASS passed, $FAILS failed, $SKIPPED skipped"
if [ $FAILS -eq 0 ]; then
    echo "Success: All sed tests passed!"
    exit 0
else
    echo "Failure: $FAILS test(s) failed."
    exit 1
fi
