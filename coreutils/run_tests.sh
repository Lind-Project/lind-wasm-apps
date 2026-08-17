#!/usr/bin/env bash
################################################################################
#
# Tests 3+ utilities from each category of coreutils:
#   File Management: ls, cp, mv, rm, mkdir, rmdir, ln, touch
#   Text Processing: cat, head, tail, wc, sort, uniq, cut, paste
#   Permissions/Info: chmod, df, du, pwd, dd
#   Text Manipulation: echo, printf, tr, expand, unexpand
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDBOOT_BIN="$LIND_WASM_ROOT/build/lind-boot"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
STAGE_DIR="$APPS_ROOT/build/coreutils/bin"
WASM_DIR="$STAGE_DIR"
LINDFS_BIN="/bin/"
TIMEOUT_SECS=10

source "$SCRIPT_DIR/../scripts/test_lib.sh"

# Test working directory — absolute path so sandbox can see it
TEST_DIR="tmp/lind-manual-tests-$$"

PASS=0
FAIL=0
TOTAL=0
LOG_FILE="manual_coreutils_results.log"

# ── Preconditions — must run before any test is recorded ───────────────────

if [[ ! -f "$STAGE_DIR/cat" ]]; then
    echo "ERROR: coreutils binaries not found at $STAGE_DIR"
    echo "Please build coreutils first by running:"
    echo "  make coreutils"
    exit 1
fi

if [[ ! -f "$LINDFS_ROOT/bin/cat" ]]; then
    echo "ERROR: coreutils is not installed in lindfs ($LINDFS_ROOT/bin/cat not found)"
    echo "Please build and install coreutils by running:"
    echo "  make coreutils"
    echo "  make install-coreutils"
    exit 1
fi

# ── Setup ────────────────────────────────────────────────────────────────────

setup() {
    # Ensure bind mounts are in place
    mkdir -p "$LINDFS_ROOT/tmp" "$LINDFS_ROOT/home" "$LINDFS_ROOT/dev"
    mkdir -p "$LINDFS_ROOT/$TEST_DIR"
}

cleanup() {
    rm -rf "$LINDFS_ROOT/$TEST_DIR"
}
trap cleanup EXIT

lind_run_stderr() {
    cat $LINDFS_ROOT/tmp/lind_run_stderr
}

# ── Helper: run a test ───────────────────────────────────────────────────────

run_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if is_skipped "$name"; then
        log_skip "$name"
        return
    fi

    ((TOTAL++))

    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $name"
        ((PASS++))
    else
        echo "  FAIL: $name"
        echo "    expected: $(echo "$expected" | head -3)"
        echo "    actual:   $(echo "$actual" | head -3)"
        local err=$(lind_run_stderr)
        [ -n "$err" ] && echo "    stderr:   $(echo "$err" | head -3)"
        ((FAIL++))
    fi
}

run_test_exitcode() {
    local name="$1"
    local expected_exit="$2"
    shift 2

    if is_skipped "$name"; then
        log_skip "$name"
        return
    fi

    ((TOTAL++))

    "$@" >/dev/null 2>&1
    local actual_exit=$?

    if [ "$expected_exit" = "$actual_exit" ]; then
        echo "  PASS: $name"
        ((PASS++))
    else
        echo "  FAIL: $name (expected exit $expected_exit, got $actual_exit)"
        ((FAIL++))
    fi
}

run_test_contains() {
    local name="$1"
    local needle="$2"
    local actual="$3"

    if is_skipped "$name"; then
        log_skip "$name"
        return
    fi

    ((TOTAL++))

    if echo "$actual" | grep -q "$needle"; then
        echo "  PASS: $name"
        ((PASS++))
    else
        echo "  FAIL: $name"
        echo "    expected to contain: $needle"
        echo "    actual: $(echo "$actual" | head -3)"
        local err=$(lind_run_stderr)
        [ -n "$err" ] && echo "    stderr: $(echo "$err" | head -3)"
        ((FAIL++))
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
setup
echo "=== Manual Coreutils Tests via Lind-boot ===" | tee "$LOG_FILE"
echo "Test dir: $TEST_DIR" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Redirect all remaining output to both terminal and log
exec > >(tee -a "$LOG_FILE") 2>&1

# ── FILE MANAGEMENT ──────────────────────────────────────────────────────────
cd $LINDFS_ROOT
echo "--- File Management ---"

# touch: create a file
timeout ${TIMEOUT_SECS}s lind_run bin/touch "$TEST_DIR/touchfile"
run_test "touch: create file" "yes" "$([ -f "$TEST_DIR/touchfile" ] && echo yes || echo no)"

# ls: list files
echo "hello" > "$TEST_DIR/lsfile1"
echo "world" > "$TEST_DIR/lsfile2"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/ls "$TEST_DIR/lsfile1" "$TEST_DIR/lsfile2")
run_test_contains "ls: list files" "lsfile1" "$actual"

# mkdir: create directory
timeout ${TIMEOUT_SECS}s lind_run bin/mkdir "$TEST_DIR/newdir"
run_test "mkdir: create dir" "yes" "$([ -d "$TEST_DIR/newdir" ] && echo yes || echo no)"

# rmdir: remove directory
timeout ${TIMEOUT_SECS}s lind_run bin/mkdir "$TEST_DIR/removeme"
timeout ${TIMEOUT_SECS}s lind_run bin/rmdir "$TEST_DIR/removeme"
run_test "rmdir: remove dir" "no" "$([ -d "$TEST_DIR/removeme" ] && echo yes || echo no)"

# cp: copy file
echo "copytest" > "$TEST_DIR/original"
timeout ${TIMEOUT_SECS}s lind_run bin/cp "$TEST_DIR/original" "$TEST_DIR/copied"
run_test "cp: copy file" "copytest" "$(cat "$TEST_DIR/copied")"

# mv: move file
echo "movetest" > "$TEST_DIR/movesrc"
timeout ${TIMEOUT_SECS}s lind_run bin/mv "$TEST_DIR/movesrc" "$TEST_DIR/movedst"
run_test "mv: move file" "movetest" "$(cat "$TEST_DIR/movedst")"
run_test "mv: source removed" "no" "$([ -f "$TEST_DIR/movesrc" ] && echo yes || echo no)"

# rm: remove file
echo "deleteme" > "$TEST_DIR/rmfile"
timeout ${TIMEOUT_SECS}s lind_run bin/rm "$TEST_DIR/rmfile"
run_test "rm: remove file" "no" "$([ -f "$TEST_DIR/rmfile" ] && echo yes || echo no)"

# ln: create symlink
echo "linktest" > "$TEST_DIR/linkoriginal"
timeout ${TIMEOUT_SECS}s lind_run bin/ln -s "$TEST_DIR/linkoriginal" "$TEST_DIR/symlink"
run_test "ln: create symlink" "linktest" "$(cat "$TEST_DIR/symlink")"

echo ""

# ── TEXT PROCESSING ──────────────────────────────────────────────────────────
echo "--- Text Processing ---"

# cat: read file
echo "cattest" > "$TEST_DIR/catfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/cat "$TEST_DIR/catfile")
run_test "cat: read file" "cattest" "$actual"

# head: first lines
printf "line1\nline2\nline3\nline4\nline5\n" > "$TEST_DIR/headfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/head -n 2 "$TEST_DIR/headfile")
expected=$(printf "line1\nline2")
run_test "head: first 2 lines" "$expected" "$actual"

# tail: last lines
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/tail -n 2 "$TEST_DIR/headfile")
expected=$(printf "line4\nline5")
run_test "tail: last 2 lines" "$expected" "$actual"

# wc: word count
echo "one two three" > "$TEST_DIR/wcfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/wc -w "$TEST_DIR/wcfile")
run_test_contains "wc: word count" "3" "$actual"

# sort: sort lines
printf "banana\napple\ncherry\n" > "$TEST_DIR/sortfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/sort "$TEST_DIR/sortfile")
expected=$(printf "apple\nbanana\ncherry")
run_test "sort: alphabetical" "$expected" "$actual"

# uniq: deduplicate
printf "aaa\naaa\nbbb\nccc\nccc\n" > "$TEST_DIR/uniqfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/uniq "$TEST_DIR/uniqfile")
expected=$(printf "aaa\nbbb\nccc")
run_test "uniq: deduplicate" "$expected" "$actual"

# cut: extract fields
printf "a:b:c\nd:e:f\n" > "$TEST_DIR/cutfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/cut -d: -f2 "$TEST_DIR/cutfile")
expected=$(printf "b\ne")
run_test "cut: extract field 2" "$expected" "$actual"

# paste: merge lines
printf "A\nB\n" > "$TEST_DIR/paste1"
printf "1\n2\n" > "$TEST_DIR/paste2"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/paste "$TEST_DIR/paste1" "$TEST_DIR/paste2")
expected=$(printf "A\t1\nB\t2")
run_test "paste: merge files" "$expected" "$actual"

echo ""

# ── PERMISSIONS & INFO ───────────────────────────────────────────────────────
echo "--- Permissions & Info ---"

# chmod: change permissions
echo "chmodtest" > "$TEST_DIR/chmodfile"
timeout ${TIMEOUT_SECS}s lind_run bin/chmod 755 "$TEST_DIR/chmodfile"
actual=$(stat -c %a "$TEST_DIR/chmodfile")
run_test "chmod: set 755" "755" "$actual"

# pwd: print working directory
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/pwd)
# pwd might return / (lindfs root) or something else, just check it runs
run_test_contains "pwd: outputs a path" "/" "$actual"

# du: disk usage
echo "dutest" > "$TEST_DIR/dufile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/du "$TEST_DIR/dufile")
run_test_contains "du: reports usage" "$TEST_DIR/dufile" "$actual"

# df: disk free
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/df)
run_test_contains "df: shows filesystem" "/" "$actual"

# dd: copy bytes
echo "ddtest" > "$TEST_DIR/ddinput"
timeout ${TIMEOUT_SECS}s lind_run bin/dd if="$TEST_DIR/ddinput" of="$TEST_DIR/ddoutput"
run_test "dd: copy file" "ddtest" "$(cat "$TEST_DIR/ddoutput")"

echo ""

# ── TEXT MANIPULATION ────────────────────────────────────────────────────────
echo "--- Text Manipulation ---"

# echo: print text
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/echo "hello world")
run_test "echo: print text" "hello world" "$actual"

# printf: formatted output
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/printf "%s-%s\n" "foo" "bar")
run_test "printf: format string" "foo-bar" "$actual"

# tr: translate characters
actual=$(echo "hello" | timeout ${TIMEOUT_SECS}s lind_run bin/tr 'a-z' 'A-Z')
run_test "tr: lowercase to upper" "HELLO" "$actual"

# expand: tabs to spaces
printf "a\tb\n" > "$TEST_DIR/expandfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/expand "$TEST_DIR/expandfile")
run_test_contains "expand: tab to spaces" "a" "$actual"

# unexpand: spaces to tabs
printf "a       b\n" > "$TEST_DIR/unexpandfile"
actual=$(timeout ${TIMEOUT_SECS}s lind_run bin/unexpand -a "$TEST_DIR/unexpandfile")
run_test_contains "unexpand: spaces to tab" "a" "$actual"

echo ""

# ── SUMMARY ──────────────────────────────────────────────────────────────────
echo "================================"
echo "=== Results ==="
echo "PASS: $PASS | FAIL: $FAIL | SKIPPED: $SKIPPED | TOTAL: $TOTAL"
echo "Log saved to: $LOG_FILE"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
