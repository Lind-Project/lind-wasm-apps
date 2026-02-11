#!/usr/bin/env bash
set -euo pipefail

################################################################################
# run_coreutils_tests_lind.sh
#
# Runs GNU coreutils test suite with binaries executing in Lind WASM sandbox
################################################################################

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
COREUTILS_ROOT="$HOME/lind-wasm-apps/coreutils"
CWASM_DIR="$HOME/lind-wasm-apps/build/bin/coreutils/wasm32-wasi"
LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"

echo "=== Coreutils Test Suite via Lind ==="
echo ""

# Validation
[[ -x "$LIND_RUN" ]] || { echo "ERROR: lind_run not found" >&2; exit 1; }
[[ -d "$CWASM_DIR" ]] || { echo "ERROR: .cwasm binaries not found" >&2; exit 1; }

# Step 1: Configure
echo "Step 1: Configuring coreutils..."
cd "$COREUTILS_ROOT"
[[ -f Makefile ]] && echo "  ✓ Already configured" || { ./configure >/dev/null 2>&1; echo "  ✓ Done"; }

# Step 2: Create wrappers
echo ""
echo "Step 2: Creating lind_run wrapper scripts..."
count=0
for cwasm in "$CWASM_DIR"/*.cwasm; do
    name=$(basename "$cwasm" .cwasm)
    wrapper_path="$COREUTILS_ROOT/src/$name"
    printf '#!/bin/bash\nexec "%s" "%s" "$@"\n' "$LIND_RUN" "$cwasm" > "$wrapper_path"
    chmod +x "$wrapper_path"
    ((count++))
done

echo "  ✓ Created $count wrappers"

# Step 3: Run tests WITH VISIBLE OUTPUT
echo ""
echo "Step 3: Running test suite..."
echo "  (Output shown below - this will take several minutes)"
echo "================================"
make -C tests check VERBOSE=yes 2>&1 | tee /tmp/coreutils_test_results.txt
echo "================================"

# Step 4: Report
echo ""
echo "=== Results ==="
pass=$(grep -c "^PASS" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
fail=$(grep -c "^FAIL" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
skip=$(grep -c "^SKIP" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
echo "PASS: $pass | FAIL: $fail | SKIP: $skip"
echo ""
echo "Full log saved to: /tmp/coreutils_test_results.txt"
