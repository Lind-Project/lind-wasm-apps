#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# grep test script for lind-wasm
#
# Usage: ./grep/run_tests.sh
#
# Steps:
#   1) Verify grep is built (staged binary exists)
#   2) Verify grep is installed in lindfs
#   3) Create test fixtures
#   4) Run sanity tests
#   5) Cleanup
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$APPS_ROOT/.." && pwd)}"
STAGE_DIR="$APPS_ROOT/build/grep/usr/local/bin"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run"
GREP_BIN="/usr/local/bin/grep"
TEST_DIR="/tests/grep"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# ----------------------------------------------------------------------
# 1) Verify grep is built
# ----------------------------------------------------------------------
echo "[test] Checking staged binary..."

if [[ ! -f "$STAGE_DIR/grep" ]]; then
  echo "  ERROR: grep binary not found at $STAGE_DIR/grep"
  echo "  Please build grep first by running:"
  echo "    make grep"
  exit 1
fi

echo "  OK: staged binary found at $STAGE_DIR/grep"

# ----------------------------------------------------------------------
# 2) Verify grep is installed in lindfs
# ----------------------------------------------------------------------
echo
echo "[test] Checking lindfs installation..."

if [[ ! -f "$LINDFS_ROOT$GREP_BIN" ]]; then
  echo "  ERROR: grep is not installed in lindfs ($LINDFS_ROOT$GREP_BIN not found)"
  echo "  Please build and install grep by running:"
  echo "    make grep"
  echo "    make install-grep"
  exit 1
fi

echo "  OK: grep installed at $LINDFS_ROOT$GREP_BIN"

# ----------------------------------------------------------------------
# 3) Create test fixtures
# ----------------------------------------------------------------------
echo
echo "[test] Creating test fixtures..."
mkdir -p "$LINDFS_ROOT/$TEST_DIR"
cat > "$LINDFS_ROOT/$TEST_DIR/hello.txt" <<'EOF'
hello world
Hello World
HELLO WORLD
this line has no match
hello again
EOF

# ----------------------------------------------------------------------
# 4) Sanity tests
# ----------------------------------------------------------------------
echo
echo "[test] Running sanity tests..."

# Test: basic pattern match
OUTPUT=$(sudo "$LIND_RUN" --enable-fpcast $GREP_BIN "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
EXPECTED=$'hello world\nhello again'
if [[ "$OUTPUT" == "$EXPECTED" ]]; then
  pass "basic pattern match"
else
  fail "basic pattern match" "expected 2 lines, got: $OUTPUT"
fi

# Test: case-insensitive
OUTPUT=$(sudo "$LIND_RUN" --enable-fpcast $GREP_BIN -i "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
if [[ "$LINE_COUNT" -eq 4 ]]; then
  pass "case-insensitive (-i)"
else
  fail "case-insensitive (-i)" "expected 4 lines, got $LINE_COUNT"
fi

# Test: count matches
OUTPUT=$(sudo "$LIND_RUN" --enable-fpcast $GREP_BIN -c "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
if [[ "$OUTPUT" == "2" ]]; then
  pass "count matches (-c)"
else
  fail "count matches (-c)" "expected '2', got '$OUTPUT'"
fi

# Test: stdin pipe
OUTPUT=$(echo "test123" | sudo "$LIND_RUN" --enable-fpcast $GREP_BIN -oE "[0-9]+" 2>/dev/null || true)
if [[ "$OUTPUT" == "123" ]]; then
  pass "stdin pipe with regex (-oE)"
else
  fail "stdin pipe with regex (-oE)" "expected '123', got '$OUTPUT'"
fi

# Test: no match returns non-zero (grep exits 1 when no match)
sudo "$LIND_RUN" --enable-fpcast $GREP_BIN "zzzznotfound" "$TEST_DIR/hello.txt" >/dev/null 2>&1 && RC=$? || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "no match returns non-zero exit"
else
  fail "no match returns non-zero exit" "expected non-zero, got $RC"
fi

# ----------------------------------------------------------------------
# 5) Cleanup test fixtures
# ----------------------------------------------------------------------
echo
echo "[test] Cleaning up test fixtures..."
rm -f "$LINDFS_ROOT/$TEST_DIR/hello.txt"

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
echo
echo "=============================="
echo " Results: $PASS passed, $FAIL failed"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
