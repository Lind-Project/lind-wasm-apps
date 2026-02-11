#!/usr/bin/env bash
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

echo ""
echo "Step 2: Creating lind_run wrapper scripts..."

mkdir -p "$COREUTILS_ROOT/src"

# Utilities to test via Lind — chosen to avoid ones the test harness
# needs internally (rm, cat, chmod, cp, mkdir, mv, ln, ls, env, etc.)
UTILS_TO_TEST=(
    base64 basename cksum comm csplit dirname expand expr factor
    fmt fold hostid join logname nl nproc od paste pathchk
    pinky pr printenv ptx readlink seq shred shuf split
    sum tsort tty unexpand uniq uptime users wc who
)

count=0
for util in "${UTILS_TO_TEST[@]}"; do
    cwasm="$CWASM_DIR/${util}.cwasm"
    [[ -f "$cwasm" ]] || continue
    wrapper_path="$COREUTILS_ROOT/src/$util"
    printf '#!/bin/bash\nexec "%s" "%s" "$@"\n' "$LIND_RUN" "$cwasm" > "$wrapper_path"
    /bin/chmod +x "$wrapper_path"
    ((count++))
done

echo "  ✓ Created $count Lind wrappers"

# Symlink all other utilities in src/ to real system binaries
# so the test harness doesn't use stale Lind wrappers
echo "  Symlinking harness utilities to system binaries..."
link_count=0
for f in "$COREUTILS_ROOT"/src/*; do
    [[ -f "$f" ]] || continue
    name=$(/usr/bin/basename "$f")

    # Skip if it's one we're testing via Lind
    skip=false
    for t in "${UTILS_TO_TEST[@]}"; do
        [[ "$name" == "$t" ]] && { skip=true; break; }
    done
    $skip && continue

    # Skip non-executable files (Makefiles, .c, .h, etc.)
    [[ -x "$f" ]] || continue

    # Find the real system binary and symlink
    sys_bin=$(PATH="/usr/bin:/bin" command -v "$name" 2>/dev/null) || continue
    /bin/ln -sf "$sys_bin" "$f"
    ((link_count++))
done

echo "  ✓ Symlinked $link_count harness utilities to system binaries"

# Step 3: Run tests
echo ""
echo "Step 3: Running test suite..."
echo "  (Output shown below - this will take several minutes)"
echo "================================"
PATH="/usr/bin:/bin:$PATH" \
    make -C tests check VERBOSE=yes 2>&1 | /usr/bin/tee /tmp/coreutils_test_results.txt
echo "================================"

# Step 4: Report
echo ""
echo "=== Results ==="
pass=$(/bin/grep -c "^PASS" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
fail=$(/bin/grep -c "^FAIL" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
skip=$(/bin/grep -c "^SKIP" /tmp/coreutils_test_results.txt 2>/dev/null || echo 0)
echo "PASS: $pass | FAIL: $fail | SKIP: $skip"
echo ""
echo "Full log saved to: /tmp/coreutils_test_results.txt"