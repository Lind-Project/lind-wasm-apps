#!/bin/bash

# For native python
PYTHON="build-native/python"
PYTHON_CHECK="build-native/python"

# Check the actual python binary exists
if [ ! -f "$PYTHON_CHECK" ]; then
    echo "Error: $PYTHON_CHECK not found." >&2
    exit 1
fi

echo "module,total_tests"

for test in $($PYTHON -m test --list-tests 2>/dev/null | awk -F. '{print $1}' | sort -u); do
    # Filter out lines that are blank lines
    # There are cases like (e.g. "1 test skipped:") which is seen in the output which as of now are not excluded
    count=$($PYTHON -m test --list-cases "$test" 2>/dev/null | grep -c '[^[:space:]]')
    echo "$test,$count"
done
