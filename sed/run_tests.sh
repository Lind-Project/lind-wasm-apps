#!/bin/bash
set -uo pipefail

LIND_WASM_ROOT="${LIND_WASM_ROOT:-/home/lind/lind-wasm}"
LINDBOOT_BIN="$LIND_WASM_ROOT/build/lind-boot"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN_CMD="lind_run"
SED_BINARY="/usr/local/bin/sed"
cd $LINDFS_ROOT

echo "Starting sed sandbox tests..."

FAILS=0

# Helper function to validate outputs
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

# 1. Basic Stream Substitution
ACTUAL=$(echo "Hello World" | $LIND_RUN_CMD $SED_BINARY 's/World/Sandbox/')
check_result "Basic Substitution" "Hello Sandbox" "$ACTUAL"

# 2. Global Substitution
ACTUAL=$(echo "apple banana apple" | $LIND_RUN_CMD $SED_BINARY 's/a[a-z]*e/orange/g')
check_result "Global Substitution" "orange banana orange" "$ACTUAL"

# 3. In-Place File Editing (-i)
# This heavily stresses file-related system calls (open, read, write, rename, unlink)
echo "Version 1.0" > test_inplace.txt
$LIND_RUN_CMD $SED_BINARY -i 's/1.0/2.0/' test_inplace.txt
ACTUAL=$(cat test_inplace.txt)
check_result "In-Place Editing" "Version 2.0" "$ACTUAL"
rm -f test_inplace.txt

# 4. Line Deletion
ACTUAL=$(printf "keep me\ndelete me\nkeep me too\n" | $LIND_RUN_CMD $SED_BINARY '/delete/d')
EXPECTED=$(printf "keep me\nkeep me too")
check_result "Line Deletion" "$EXPECTED" "$ACTUAL"

# 5. Selective Printing (-n)
ACTUAL=$(printf "apple\nbanana\ncherry\n" | $LIND_RUN_CMD $SED_BINARY -n '/banana/p')
check_result "Selective Printing" "banana" "$ACTUAL"

# 6. Multiple Commands (-e)
ACTUAL=$(echo "foo and bar" | $LIND_RUN_CMD $SED_BINARY -e 's/foo/baz/' -e 's/bar/qux/')
check_result "Multiple Commands" "baz and qux" "$ACTUAL"

# 7. Reading Commands from a Script (-f)
echo "s/cat/dog/g" > script.sed
ACTUAL=$(echo "The cat chased the other cat." | $LIND_RUN_CMD $SED_BINARY -f script.sed)
check_result "Script File" "The dog chased the other dog." "$ACTUAL"
rm -f script.sed

echo "-----------------------------------"
if [ $FAILS -eq 0 ]; then
    echo "Success: All sed tests passed!"
    exit 0
else
    echo "Failure: $FAILS test(s) failed."
    exit 1
fi
