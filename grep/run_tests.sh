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
TIMEOUT_SECS="${TIMEOUT_SECS:-10}"

source "$SCRIPT_DIR/../scripts/test_lib.sh"

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
trap 'rm -f "$LINDFS_ROOT/$TEST_DIR/hello.txt"' EXIT
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
if is_skipped "basic pattern match"; then
  log_skip "basic pattern match"
else
  OUTPUT=$(sudo timeout "${TIMEOUT_SECS}s" "$LIND_RUN" $GREP_BIN "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
  EXPECTED=$'hello world\nhello again'
  if [[ "$OUTPUT" == "$EXPECTED" ]]; then
    pass "basic pattern match"
  else
    fail "basic pattern match" "expected 2 lines, got: $OUTPUT"
  fi
fi

# Test: case-insensitive
if is_skipped "case-insensitive (-i)"; then
  log_skip "case-insensitive (-i)"
else
  OUTPUT=$(sudo timeout "${TIMEOUT_SECS}s" "$LIND_RUN" $GREP_BIN -i "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
  LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
  if [[ "$LINE_COUNT" -eq 4 ]]; then
    pass "case-insensitive (-i)"
  else
    fail "case-insensitive (-i)" "expected 4 lines, got $LINE_COUNT"
  fi
fi

# Test: count matches
if is_skipped "count matches (-c)"; then
  log_skip "count matches (-c)"
else
  OUTPUT=$(sudo timeout "${TIMEOUT_SECS}s" "$LIND_RUN" $GREP_BIN -c "hello" "$TEST_DIR/hello.txt" 2>/dev/null || true)
  if [[ "$OUTPUT" == "2" ]]; then
    pass "count matches (-c)"
  else
    fail "count matches (-c)" "expected '2', got '$OUTPUT'"
  fi
fi

# Test: stdin pipe
if is_skipped "stdin pipe with regex (-oE)"; then
  log_skip "stdin pipe with regex (-oE)"
else
  OUTPUT=$(echo "test123" | sudo timeout "${TIMEOUT_SECS}s" "$LIND_RUN" $GREP_BIN -oE "[0-9]+" 2>/dev/null || true)
  if [[ "$OUTPUT" == "123" ]]; then
    pass "stdin pipe with regex (-oE)"
  else
    fail "stdin pipe with regex (-oE)" "expected '123', got '$OUTPUT'"
  fi
fi

# Test: no match returns non-zero (grep exits 1 when no match)
if is_skipped "no match returns non-zero exit"; then
  log_skip "no match returns non-zero exit"
else
  sudo timeout "${TIMEOUT_SECS}s" "$LIND_RUN" $GREP_BIN "zzzznotfound" "$TEST_DIR/hello.txt" >/dev/null 2>&1 && RC=$? || RC=$?
  if [[ "$RC" -ne 0 ]]; then
    pass "no match returns non-zero exit"
  else
    fail "no match returns non-zero exit" "expected non-zero, got $RC"
  fi
fi

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
TOTAL=$((PASS + FAIL + SKIPPED))
echo
echo "=============================="
echo " Results: $TOTAL total, $PASS passed, $FAIL failed, $SKIPPED skipped"
echo "=============================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
