#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# grep test script for lind-wasm
#
# Usage: ./grep/test_grep.sh [--skip-build]
#
# Steps:
#   1) Build grep (unless --skip-build)
#   2) Verify binaries exist
#   3) Install into lindfs
#   4) Run sanity tests
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$APPS_ROOT/.." && pwd)}"
STAGE_DIR="$APPS_ROOT/build/bin/grep/wasm32-wasi"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"

SKIP_BUILD=0
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1 — $2"; SKIP=$((SKIP + 1)); }

# ----------------------------------------------------------------------
# 1) Build grep
# ----------------------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "[test] Building grep..."
  bash "$SCRIPT_DIR/compile_grep.sh"
else
  echo "[test] Skipping build (--skip-build)"
fi

# ----------------------------------------------------------------------
# 2) Verify binaries exist
# ----------------------------------------------------------------------
echo
echo "[test] Checking build artifacts..."

if [[ -f "$STAGE_DIR/grep.wasm" ]]; then
  pass "grep.wasm exists"
else
  fail "grep.wasm exists" "not found at $STAGE_DIR/grep.wasm"
fi

if [[ -f "$STAGE_DIR/grep.opt.wasm" ]]; then
  pass "grep.opt.wasm exists"
else
  fail "grep.opt.wasm exists" "not found at $STAGE_DIR/grep.opt.wasm"
fi

if [[ -f "$STAGE_DIR/grep.cwasm" ]]; then
  pass "grep.cwasm exists"
else
  skip "grep.cwasm exists" "precompilation may not be available"
fi

# ----------------------------------------------------------------------
# 3) Install into lindfs
# ----------------------------------------------------------------------
echo
echo "[test] Installing grep into lindfs..."
mkdir -p "$LINDFS_ROOT/bin"
cp "$STAGE_DIR/grep.opt.wasm" "$LINDFS_ROOT/bin/grep"
echo "  Installed grep.opt.wasm -> $LINDFS_ROOT/bin/grep"

# Create test fixtures
mkdir -p "$LINDFS_ROOT/testfiles"
cat > "$LINDFS_ROOT/testfiles/hello.txt" <<'EOF'
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
OUTPUT=$(sudo "$LIND_RUN" /bin/grep "hello" /testfiles/hello.txt 2>/dev/null || true)
EXPECTED=$'hello world\nhello again'
if [[ "$OUTPUT" == "$EXPECTED" ]]; then
  pass "basic pattern match"
else
  fail "basic pattern match" "expected 2 lines, got: $OUTPUT"
fi

# Test: case-insensitive
OUTPUT=$(sudo "$LIND_RUN" /bin/grep -i "hello" /testfiles/hello.txt 2>/dev/null || true)
LINE_COUNT=$(echo "$OUTPUT" | wc -l | tr -d ' ')
if [[ "$LINE_COUNT" -eq 4 ]]; then
  pass "case-insensitive (-i)"
else
  fail "case-insensitive (-i)" "expected 4 lines, got $LINE_COUNT"
fi

# Test: count matches
OUTPUT=$(sudo "$LIND_RUN" /bin/grep -c "hello" /testfiles/hello.txt 2>/dev/null || true)
if [[ "$OUTPUT" == "2" ]]; then
  pass "count matches (-c)"
else
  fail "count matches (-c)" "expected '2', got '$OUTPUT'"
fi

# Test: stdin pipe
OUTPUT=$(echo "test123" | sudo "$LIND_RUN" /bin/grep -oE "[0-9]+" 2>/dev/null || true)
if [[ "$OUTPUT" == "123" ]]; then
  pass "stdin pipe with regex (-oE)"
else
  fail "stdin pipe with regex (-oE)" "expected '123', got '$OUTPUT'"
fi

# Test: no match returns non-zero (grep exits 1 when no match)
sudo "$LIND_RUN" /bin/grep "zzzznotfound" /testfiles/hello.txt >/dev/null 2>&1 && RC=$? || RC=$?
if [[ "$RC" -ne 0 ]]; then
  pass "no match returns non-zero exit"
else
  fail "no match returns non-zero exit" "expected non-zero, got $RC"
fi

# ----------------------------------------------------------------------
# Cleanup test fixtures
# ----------------------------------------------------------------------
echo
echo "[test] Cleaning up test fixtures..."
rm -f "$LINDFS_ROOT/testfiles/hello.txt"

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
