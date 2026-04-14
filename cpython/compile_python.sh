#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
$SCRIPT_DIR/build_python_native.sh
$SCRIPT_DIR/build_python_wasm.sh
if [[ "$LIND_DYLINK" == "1" ]]; then
	$SCRIPT_DIR/build_shared_python_wasm.sh
fi
