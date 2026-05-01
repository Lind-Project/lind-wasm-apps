#!/bin/bash

PYTHON="build-native/python"

# Check build-native exists
if [ ! -f "$PYTHON" ]; then
    echo "Error: $PYTHON not found. Please build native Python first." >&2
    exit 1
fi

echo "module,total_tests"

for test in $($PYTHON -m test --list-tests 2>/dev/null | awk -F. '{print $1}' | sort -u); do
    count=$($PYTHON -m test --list-cases "$test" 2>/dev/null | wc -l)
    echo "$test,$count"
done
