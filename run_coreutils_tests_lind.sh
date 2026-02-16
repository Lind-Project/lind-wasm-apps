#!/usr/bin/env bash
################################################################################
# run_coreutils_tests_lind.sh
#
# Runs the GNU coreutils test suite with ALL available binaries executing
# inside the Lind WASM sandbox (via lind-boot).
#
# KEY INSIGHT: lind-boot uses lindfs/ as an isolated filesystem root.
# Binaries must be copied into lindfs/ and referenced by their lindfs-relative
# path. We use .opt.wasm files (not .cwasm which are ELF, not WASM).
#
# STRATEGY: Per-directory swap
# ----------------------------
# For each test directory:
#   1. Start with ALL utilities as native symlinks in src/
#   2. Swap ONLY the utility being tested to a Lind wrapper
#   3. Run that directory's tests
#   4. Swap it back to native
#
# For misc/ tests, wrap all non-harness-critical utilities.
################################################################################

set -euo pipefail

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
COREUTILS_ROOT="$HOME/lind-wasm-apps/coreutils"
WASM_DIR="$HOME/lind-wasm-apps/build/bin/coreutils/wasm32-wasi"
LINDBOOT_BIN="$LIND_WASM_ROOT/build/lind-boot"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
RESULTS_FILE="/tmp/coreutils_test_results.txt"
SRC_DIR="$COREUTILS_ROOT/src"

# Where .opt.wasm files live inside lindfs
LINDFS_BIN="/opt/coreutils"

echo "=== Coreutils Test Suite via Lind ==="
echo ""

# ── Validation ────────────────────────────────────────────────────────────────
[[ -x "$LINDBOOT_BIN" ]] || { echo "ERROR: lind-boot not found at $LINDBOOT_BIN" >&2; exit 1; }
[[ -d "$WASM_DIR" ]] || { echo "ERROR: .opt.wasm binaries not found in $WASM_DIR" >&2; exit 1; }

# ── Step 1: Copy .opt.wasm binaries into lindfs ─────────────────────────────
echo "Step 1: Setting up lindfs with .opt.wasm binaries..."

sudo /bin/mkdir -p "$LINDFS_ROOT/$LINDFS_BIN"
sudo /bin/mkdir -p "$LINDFS_ROOT/dev"
sudo /bin/touch "$LINDFS_ROOT/dev/null" 2>/dev/null || true

wasm_count=0
for wasm in "$WASM_DIR"/*.opt.wasm; do
    [[ -f "$wasm" ]] || continue
    util=$(/usr/bin/basename "$wasm" .opt.wasm)
    sudo /bin/cp "$wasm" "$LINDFS_ROOT/$LINDFS_BIN/${util}.opt.wasm"
    ((wasm_count++)) || true
done
echo "  * Copied $wasm_count .opt.wasm binaries into lindfs"

# Set up bind mounts so sandbox can access host filesystem
echo "  * Setting up bind mounts for sandbox filesystem access..."
sudo /bin/mkdir -p "$LINDFS_ROOT/home" "$LINDFS_ROOT/tmp" "$LINDFS_ROOT/usr" "$LINDFS_ROOT/proc"
# Unmount first in case they're already mounted from a previous run
sudo umount "$LINDFS_ROOT/home" 2>/dev/null || true
sudo umount "$LINDFS_ROOT/tmp" 2>/dev/null || true
sudo umount "$LINDFS_ROOT/usr" 2>/dev/null || true
sudo umount "$LINDFS_ROOT/proc" 2>/dev/null || true
sudo mount --bind /home "$LINDFS_ROOT/home"
sudo mount --bind /tmp "$LINDFS_ROOT/tmp"
sudo mount --bind /usr "$LINDFS_ROOT/usr"
sudo mount --bind /proc "$LINDFS_ROOT/proc" 2>/dev/null || true
echo "  * Bind mounts ready"

# Cleanup function to unmount on exit
cleanup() {
    echo ""
    echo "Cleaning up bind mounts..."
    sudo umount "$LINDFS_ROOT/home" 2>/dev/null || true
    sudo umount "$LINDFS_ROOT/tmp" 2>/dev/null || true
    sudo umount "$LINDFS_ROOT/usr" 2>/dev/null || true
    sudo umount "$LINDFS_ROOT/proc" 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 2: Set up ALL utilities as native symlinks ──────────────────────────
cd "$COREUTILS_ROOT"
echo ""
echo "Step 2: Setting up all utilities as native symlinks..."

/bin/mkdir -p "$SRC_DIR"

native_count=0
for wasm in "$WASM_DIR"/*.opt.wasm; do
    [[ -f "$wasm" ]] || continue
    util=$(/usr/bin/basename "$wasm" .opt.wasm)
    target="$SRC_DIR/$util"
    sys_bin=$(PATH="/usr/bin:/bin" command -v "$util" 2>/dev/null) || continue
    /bin/rm -f "$target" 2>/dev/null || true
    /bin/ln -sf "$sys_bin" "$target"
    ((native_count++)) || true
done

# Also symlink any other executables in src/ to native
for f in "$SRC_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ -x "$f" ]] || continue
    name=$(/usr/bin/basename "$f")
    [[ -f "$WASM_DIR/${name}.opt.wasm" ]] && continue
    sys_bin=$(PATH="/usr/bin:/bin" command -v "$name" 2>/dev/null) || continue
    /bin/rm -f "$f" 2>/dev/null || true
    /bin/ln -sf "$sys_bin" "$f"
done

echo "  * Symlinked $native_count utilities to native"

# ── Helper functions ─────────────────────────────────────────────────────────

swap_to_lind() {
    local util="$1"
    local wasm_path="$LINDFS_BIN/${util}.opt.wasm"
    local target="$SRC_DIR/$util"
    [[ -f "$LINDFS_ROOT/$wasm_path" ]] || return 1
    /bin/rm -f "$target" 2>/dev/null || true
    cat > "$target" <<WRAPPER
#!/bin/bash
exec sudo LINDFS_ROOT="$LINDFS_ROOT" "$LINDBOOT_BIN" "$wasm_path" "\$@"
WRAPPER
    /bin/chmod +x "$target"
}

swap_to_native() {
    local util="$1"
    local target="$SRC_DIR/$util"
    local sys_bin
    sys_bin=$(PATH="/usr/bin:/bin" command -v "$util" 2>/dev/null) || return 1
    /bin/rm -f "$target" 2>/dev/null || true
    /bin/ln -sf "$sys_bin" "$target"
}

get_tests_for_dir() {
    local dir="$1"
    # pr/ is special: all tests run through a single pr/pr-tests script
    if [[ "$dir" == "pr" ]]; then
        echo "pr/pr-tests"
        return
    fi
    /bin/grep -oP "(?<=\s)${dir}/[a-zA-Z0-9_-]+" \
        "$COREUTILS_ROOT/tests/Makefile" | sort -u
}

# ── Step 3: Run tests per directory ──────────────────────────────────────────
echo ""
echo "Step 3: Running tests per utility directory..."
echo ""

# Clear results file
> "$RESULTS_FILE"

# Map test directories to utility names
declare -A DIR_TO_UTIL=(
    [rm]=rm
    [chmod]=chmod
    [cp]=cp
    [mv]=mv
    [ls]=ls
    [du]=du
    [tail-2]=tail
    [touch]=touch
    [mkdir]=mkdir
    [dd]=dd
    [ln]=ln
    [chgrp]=chgrp
    [chown]=chown
    [rmdir]=rmdir
    [df]=df
    [id]=id
    [pr]=pr
    [install]=ginstall
    [readlink]=readlink
)

total_pass=0
total_fail=0
total_skip=0

for test_dir in "${!DIR_TO_UTIL[@]}"; do
    util="${DIR_TO_UTIL[$test_dir]}"

    [[ -f "$LINDFS_ROOT/$LINDFS_BIN/${util}.opt.wasm" ]] || {
        echo "--- Skipping $util (no .opt.wasm) ---"
        echo ""
        continue
    }

    tests=$(get_tests_for_dir "$test_dir") || true
    [[ -n "$tests" ]] || continue

    test_count=$(echo "$tests" | wc -l)
    echo "--- Testing $util ($test_dir/: $test_count tests) ---"

    # Swap this utility to Lind
    swap_to_lind "$util"

    # Run tests with 5 min timeout, kill whole process group
    dir_results="/tmp/coreutils_${test_dir}_results.txt"
    tests_oneline=$(echo "$tests" | tr '\n' ' ')
    timeout --kill-after=10s --signal=KILL 300 \
        bash -c "cd \"$COREUTILS_ROOT\" && PATH=\"/usr/bin:/bin:\$PATH\" make -C tests check TESTS=\"$tests_oneline\" 2>&1" \
        | /usr/bin/tee "$dir_results" || true
    # Clean up any leftover lind-boot processes
    sudo pkill -9 -x lind-boot 2>/dev/null || true
    sleep 1

    # Swap back to native
    swap_to_native "$util" 2>/dev/null || true

    # Count results
    p=$(/bin/grep -c "^PASS:" "$dir_results" 2>/dev/null) || p=0
    f=$(/bin/grep -c "^FAIL:" "$dir_results" 2>/dev/null) || f=0
    s=$(/bin/grep -c "^SKIP:" "$dir_results" 2>/dev/null) || s=0
    p="${p//[^0-9]/}"; p="${p:-0}"
    f="${f//[^0-9]/}"; f="${f:-0}"
    s="${s//[^0-9]/}"; s="${s:-0}"
    echo "  $util: PASS=$p FAIL=$f SKIP=$s"
    echo ""

    total_pass=$((total_pass + p))
    total_fail=$((total_fail + f))
    total_skip=$((total_skip + s))

    /bin/cat "$dir_results" >> "$RESULTS_FILE"
done

# ── Step 4: Run misc/ tests with non-harness utilities wrapped ───────────────
echo "--- Testing misc/ utilities ---"

# Utilities that must stay native for harness functionality
HARNESS_NATIVE=(
    cat chmod cp cut date dd du echo env false head id
    kill ln ls mkdir mktemp mv nice nohup printf pwd
    rm rmdir sleep sort stat stty sync tac tail tee
    test timeout touch tr true truncate
)

declare -A NATIVE_MAP
for u in "${HARNESS_NATIVE[@]}"; do
    NATIVE_MAP["$u"]=1
done

# Wrap all non-harness utilities for misc/ tests
wrapped_for_misc=""
for wasm in "$WASM_DIR"/*.opt.wasm; do
    [[ -f "$wasm" ]] || continue
    util=$(/usr/bin/basename "$wasm" .opt.wasm)
    if [[ -z "${NATIVE_MAP[$util]:-}" ]]; then
        swap_to_lind "$util" 2>/dev/null && wrapped_for_misc="$wrapped_for_misc $util"
    fi
done
echo "  Lind-wrapped for misc/: $wrapped_for_misc"

misc_tests=$(get_tests_for_dir "misc") || true
misc_count=$(echo "$misc_tests" | wc -l)
echo "  Running $misc_count misc/ tests..."

dir_results="/tmp/coreutils_misc_results.txt"
misc_tests_oneline=$(echo "$misc_tests" | tr '\n' ' ')
timeout --kill-after=10s --signal=KILL 600 \
    bash -c "cd \"$COREUTILS_ROOT\" && PATH=\"/usr/bin:/bin:\$PATH\" make -C tests check TESTS=\"$misc_tests_oneline\" 2>&1" \
    | /usr/bin/tee "$dir_results" || true
sudo pkill -9 -x lind-boot 2>/dev/null || true
sleep 1

# Swap everything back to native
for wasm in "$WASM_DIR"/*.opt.wasm; do
    [[ -f "$wasm" ]] || continue
    util=$(/usr/bin/basename "$wasm" .opt.wasm)
    swap_to_native "$util" 2>/dev/null || true
done

p=$(/bin/grep -c "^PASS:" "$dir_results" 2>/dev/null) || p=0
f=$(/bin/grep -c "^FAIL:" "$dir_results" 2>/dev/null) || f=0
s=$(/bin/grep -c "^SKIP:" "$dir_results" 2>/dev/null) || s=0
p="${p//[^0-9]/}"; p="${p:-0}"
f="${f//[^0-9]/}"; f="${f:-0}"
s="${s//[^0-9]/}"; s="${s:-0}"
echo "  misc: PASS=$p FAIL=$f SKIP=$s"
echo ""

total_pass=$((total_pass + p))
total_fail=$((total_fail + f))
total_skip=$((total_skip + s))

/bin/cat "$dir_results" >> "$RESULTS_FILE"

# ── Step 5: Report ───────────────────────────────────────────────────────────
echo "================================"
echo ""
echo "=== Final Results ==="
echo "PASS: $total_pass | FAIL: $total_fail | SKIP: $total_skip"
echo ""
echo "Full log saved to: $RESULTS_FILE"
echo "Detailed per-test logs: $COREUTILS_ROOT/tests/test-suite.log"