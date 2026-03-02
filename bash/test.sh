i#!/bin/bash
# test.sh
# Copies the bash test runner into lindfs and executes it via lind-boot

LINDFS="${LINDFS:-/home/lind/lind-wasm/lindfs}"
LIND_BOOT="${LIND_BOOT:-sudo /home/lind/lind-wasm/src/lind-boot/target/debug/lind-boot}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_RUNNER="bash_test_runner.sh"
DEST_NAME="bash_test_runner.sh"

if [ ! -f "$SCRIPT_DIR/$TEST_RUNNER" ]; then
    echo "ERROR: $TEST_RUNNER not found in $SCRIPT_DIR"
    exit 1
fi

DEST_DIR="$LINDFS/tests/bash"
if [ ! -d "$DEST_DIR" ]; then
    echo "Creating $DEST_DIR ..."
    mkdir -p "$DEST_DIR"
fi

echo "Copying $TEST_RUNNER -> $DEST_DIR/$DEST_NAME"
cp "$SCRIPT_DIR/$TEST_RUNNER" "$DEST_DIR/$DEST_NAME"
chmod +x "$DEST_DIR/$DEST_NAME"
cd "$LINDFS" && \
    $LIND_BOOT bin/bash tests/bash/bash_test_runner.sh
