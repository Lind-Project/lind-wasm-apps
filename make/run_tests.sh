#!/bin/bash
# ─────────────────────────────────────────────────────────────
# make/run_tests.sh
# Sanity test suite for GNU make in Lind/wasm sandbox
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"

mkdir -p "$LINDFS_ROOT/tests/make"

PASS=0
FAIL=0
TOTAL=0
counter=1
TIMEOUT_SECS=10

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# assert_make: writes a Makefile into lindfs and runs make -f
#   $1 = description
#   $2 = expected output
#   $3 = Makefile contents
#   $4 = make target (default: all)
# ─────────────────────────────────────────────────────────────
assert_make() {
    local description="$1"
    local expected="$2"
    local makefile="$3"
    local target="${4:-all}"

    local mfname="Makefile$counter"
    local mfpath="$LINDFS_ROOT/tests/make/$mfname"
    counter=$((counter + 1))

    printf '%s' "$makefile" > "$mfpath"
    echo "RUNNING $description........"

    local actual
    actual=$(timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast \
        --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
        usr/local/bin/make -f "tests/make/$mfname" "$target" 2>/dev/null)

    local exit_code=$?
    TOTAL=$((TOTAL + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC} $description"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $description"
        echo    "       expected: $(echo "$expected" | head -5)"
        echo    "       actual  : $(echo "$actual"   | head -5)"
        FAIL=$((FAIL + 1))
    fi
    if [ $exit_code -eq 124 ]; then
        echo -e "  ${RED}HANG${NC} $description (Timed out after ${TIMEOUT_SECS}s)"
    fi
}

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────
# Check binary exists in lindfs before running
# ─────────────────────────────────────────────────────────────
if [[ ! -f "$LINDFS_ROOT/usr/local/bin/make" ]]; then
    echo -e "[ ${RED}MISSING${NC} ] $LINDFS_ROOT/usr/local/bin/make"
    echo "Run make install-gmake first"
    exit 1
fi

# ═════════════════════════════════════════════════════════════
section "1. Basic Rules"
# ═════════════════════════════════════════════════════════════

assert_make "simple echo rule" \
    "hello" \
$'all:\n\t@echo hello'

assert_make "variable expansion" \
    "world" \
$'MSG = world\nall:\n\t@echo $(MSG)'

assert_make "multiple targets in order" \
    "one
two" \
$'all: one two\none:\n\t@echo one\ntwo:\n\t@echo two'

assert_make "phony target runs" \
    "clean done" \
$'.PHONY: all\nall:\n\t@echo clean done'

assert_make "dependency chain" \
    "b
a" \
$'all: a\na: b\n\t@echo a\nb:\n\t@echo b'

assert_make "multiple rules same target" \
    "first
second" \
$'all:\n\t@echo first\n\t@echo second'

# ═════════════════════════════════════════════════════════════
section "2. Variables"
# ═════════════════════════════════════════════════════════════

assert_make "immediate assignment :=" \
    "hello" \
$'X := hello\nall:\n\t@echo $(X)'

assert_make "append +=" \
    "hello world" \
$'X := hello\nX += world\nall:\n\t@echo $(X)'

assert_make "conditional ?= unset" \
    "default" \
$'X ?= default\nall:\n\t@echo $(X)'

assert_make "override with env" \
    "hello" \
$'X = hello\nall:\n\t@echo $(X)'

assert_make "nested variable" \
    "hello" \
$'A = hello\nB = $(A)\nall:\n\t@echo $(B)'

assert_make "empty variable" \
    "" \
$'X =\nall:\n\t@echo $(X)'

# ═════════════════════════════════════════════════════════════
section "3. Functions"
# ═════════════════════════════════════════════════════════════

assert_make "subst function" \
    "h-llo" \
$'all:\n\t@echo $(subst e,-,hello)'

assert_make "patsubst function" \
    "a.o b.o" \
$'SRCS = a.c b.c\nall:\n\t@echo $(patsubst %.c,%.o,$(SRCS))'

assert_make "strip function" \
    "hello world" \
$'all:\n\t@echo $(strip   hello   world  )'

assert_make "words function" \
    "1" \
$'all:\n\t@echo $(words hello)'

assert_make "foreach function" \
    "a.o b.o c.o" \
$'NAMES = a b c\nall:\n\t@echo $(foreach n,$(NAMES),$(n).o)'

assert_make "if function true" \
    "yes" \
$'all:\n\t@echo $(if 1,yes,no)'

assert_make "if function false" \
    "no" \
$'all:\n\t@echo $(if ,yes,no)'

assert_make "filter function" \
    "a.c b.c" \
$'FILES = a.c b.c a.h\nall:\n\t@echo $(filter %.c,$(FILES))'

assert_make "filter-out function" \
    "a.h" \
$'FILES = a.c b.c a.h\nall:\n\t@echo $(filter-out %.c,$(FILES))'

assert_make "sort function" \
    "a b c" \
$'all:\n\t@echo $(sort c a b)'

# ═════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE} Results${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " Total : $TOTAL"
echo -e " ${GREEN}Pass${NC}  : $PASS"
echo -e " ${RED}Fail${NC}  : $FAIL"
echo ""
if [ $FAIL -gt 0 ]; then
    echo -e "${RED}FAILED${NC} — $FAIL/$TOTAL tests failed"
    exit 1
else
    echo -e "${GREEN}ALL PASSED${NC} — $PASS/$TOTAL tests passed"
    exit 0
fi