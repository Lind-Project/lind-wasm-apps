#!/bin/bash

# Usage: bash generate_test_counts.sh [native|wasm]
# Default is native

MODE=${1:-native}

if [ "$MODE" = "wasm" ]; then
    PYTHON="lind_run --preload env=lib/libz.so --preload env=lib/libpython3.14.so usr/local/bin/python"
else
    PYTHON="build-native/python"
    if [ ! -f "$PYTHON" ]; then
        echo "Error: $PYTHON not found. Please build native Python first." >&2
        exit 1
    fi
fi

echo "module,total_tests"

for test in $($PYTHON -m test --list-tests 2>/dev/null | awk -F. '{print $1}' | sort -u); do
    # Filter out blank lines
    # Note: lines like "1 test skipped:" are not excluded and will be counted
    count=$($PYTHON -m test --list-cases "$test" 2>/dev/null | grep -c '[^[:space:]]')
    echo "$test,$count"
done
