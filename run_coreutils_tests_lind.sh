#!/usr/bin/env bash
################################################################################
# run_coreutils_tests_lind.sh
#
# Runs the GNU coreutils test suite with selected binaries executing inside
# the Lind WASM sandbox (via lind_run).
#
# OVERVIEW
# --------
# The coreutils test suite expects utilities to live in coreutils/src/.
# We replace a targeted subset of those with thin wrapper scripts that invoke
# the corresponding .cwasm binary through lind_run.  All other utilities
# (rm, cat, chmod, cp, …) are symlinked to the real host binaries so the
# test harness infrastructure can function normally.
#
# WHY NOT WRAP EVERYTHING?
# The test framework (test-lib.sh, Makefiles) internally calls rm, cat,
# chmod, mkdir, mktemp, etc. to create temp dirs, capture logs, and clean
# up.  If those are also routed through the Lind sandbox they fail because
# the sandbox cannot access arbitrary host paths.  So we only wrap the
# utilities we actually want to test in Lind.
#
# USAGE
#   ./run_coreutils_tests_lind.sh
#
# REQUIREMENTS
#   - lind-wasm built (LIND_WASM_ROOT or ~/lind-wasm)
#   - coreutils WASM binaries built (make coreutils from lind-wasm-apps)
#   - coreutils source configured (./configure already run)
#
# OUTPUT
#   - Live test output on stdout
#   - Full log saved to /tmp/coreutils_test_results.txt
#   - Summary of PASS / FAIL / SKIP counts
################################################################################

set -euo pipefail

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
COREUTILS_ROOT="$HOME/lind-wasm-apps/coreutils"
CWASM_DIR="$HOME/lind-wasm-apps/build/bin/coreutils/wasm32-wasi"
LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"
RESULTS_FILE="/tmp/coreutils_test_results.txt"

echo "=== Coreutils Test Suite via Lind ==="
echo ""

# ── Validation ────────────────────────────────────────────────────────────────
[[ -x "$LIND_RUN" ]] || { echo "ERROR: lind_run not found at $LIND_RUN" >&2; exit 1; }
[[ -d "$CWASM_DIR" ]] || { echo "ERROR: .cwasm binaries not found in $CWASM_DIR" >&2; exit 1; }

# ── Step 1: Configure ────────────────────────────────────────────────────────
echo "Step 1: Configuring coreutils..."
cd "$COREUTILS_ROOT"
if [[ -f Makefile ]]; then
    echo "  ✓ Already configured"
else
    ./configure >/dev/null 2>&1
    echo "  ✓ Configured"
fi

# ── Step 2: Create Lind wrappers ─────────────────────────────────────────────
echo ""
echo "Step 2: Creating lind_run wrapper scripts..."

/bin/mkdir -p "$COREUTILS_ROOT/src"

# Utilities to test through Lind.
# These were chosen to avoid utilities that the test harness itself depends on
# (rm, cat, chmod, cp, mkdir, mv, ln, ls, env, echo, head, tail, tee, etc.).
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

# ── Step 3: Symlink remaining utilities to host binaries ─────────────────────
# Any executable in src/ that is NOT in UTILS_TO_TEST gets symlinked to the
# real system binary.  This ensures the test harness (which calls rm, cat,
# chmod, etc.) uses working host tools, not stale Lind wrappers from a
# previous run or broken cross-compiled binaries.
echo "  Symlinking harness utilities to system binaries..."

link_count=0
for f in "$COREUTILS_ROOT"/src/*; do
    [[ -f "$f" ]] || continue
    name=$(/usr/bin/basename "$f")

    # Skip utilities we are testing via Lind
    skip=false
    for t in "${UTILS_TO_TEST[@]}"; do
        [[ "$name" == "$t" ]] && { skip=true; break; }
    done
    $skip && continue

    # Skip non-executable files (Makefile, *.c, *.h, *.o, etc.)
    [[ -x "$f" ]] || continue

    # Find the real system binary and replace with symlink
    sys_bin=$(PATH="/usr/bin:/bin" command -v "$name" 2>/dev/null) || continue
    /bin/ln -sf "$sys_bin" "$f"
    ((link_count++))
done

echo "  ✓ Symlinked $link_count harness utilities to system binaries"

# ── Step 4: Run tests ────────────────────────────────────────────────────────
echo ""
echo "Step 4: Running test suite..."
echo "  (Output shown below — this will take several minutes)"
echo "================================"

# Prepend /usr/bin:/bin so that make and any tools it spawns resolve to real
# host binaries first.  The test suite itself uses explicit paths to
# $abs_top_builddir/src/UTIL, so the Lind wrappers are still invoked for the
# utilities under test.
PATH="/usr/bin:/bin:$PATH" \
    make -C tests check VERBOSE=yes 2>&1 | /usr/bin/tee "$RESULTS_FILE"

echo "================================"

# ── Step 5: Report ───────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
pass=$(/bin/grep -c "^PASS:" "$RESULTS_FILE" 2>/dev/null || echo 0)
fail=$(/bin/grep -c "^FAIL:" "$RESULTS_FILE" 2>/dev/null || echo 0)
skip=$(/bin/grep -c "^SKIP:" "$RESULTS_FILE" 2>/dev/null || echo 0)
echo "PASS: $pass | FAIL: $fail | SKIP: $skip"
echo ""
echo "Full log saved to: $RESULTS_FILE"
echo "Detailed per-test logs: $COREUTILS_ROOT/tests/test-suite.log"