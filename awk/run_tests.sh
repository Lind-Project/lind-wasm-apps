#!/bin/bash
# ─────────────────────────────────────────────────────────────
# awk/run_tests.sh
# Sanity test suite for gawk in Lind/wasm sandbox
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"

mkdir -p "$LINDFS_ROOT/tests/awk"

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
# assert_awk: runs a gawk program via lind_run
#   $1 = description
#   $2 = expected output
#   $3 = awk program string
#   $4 = (optional) input string piped to awk
# ─────────────────────────────────────────────────────────────
assert_awk() {
    local description="$1"
    local expected="$2"
    local program="$3"
    local input="${4:-}"

    local scriptfile="tests/awk/test$counter.awk"
    local scriptfile_path="$LINDFS_ROOT/tests/awk/test$counter.awk"
    counter=$((counter + 1))

    echo "$program" > "$scriptfile_path"
    echo "RUNNING $description........"

    local actual
    if [[ -n "$input" ]]; then
        actual=$(echo "$input" | timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast \
            --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
            usr/local/bin/gawk -f "$scriptfile" 2>/dev/null)
    else
        actual=$(timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast \
            --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
            usr/local/bin/gawk -f "$scriptfile" /dev/null 2>/dev/null)
    fi

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
if [[ ! -f "$LINDFS_ROOT/usr/local/bin/gawk" ]]; then
    echo -e "[ ${RED}MISSING${NC} ] $LINDFS_ROOT/usr/local/bin/gawk"
    echo "Run make install-awk first"
    exit 1
fi

# ═════════════════════════════════════════════════════════════
section "1. Basic Print & Fields"
# ═════════════════════════════════════════════════════════════

assert_awk "print full line"        "hello world"   '{ print }' \
    "hello world"

assert_awk "print field 1"          "hello"         '{ print $1 }' \
    "hello world"

assert_awk "print field 2"          "world"         '{ print $2 }' \
    "hello world"

assert_awk "NF (field count)"       "3"             '{ print NF }' \
    "a b c"

assert_awk "NR (record number)"     "1
2
3" \
    '{ print NR }' \
    "a
b
c"

assert_awk "custom FS comma"        "b"             'BEGIN{FS=","} { print $2 }' \
    "a,b,c"

assert_awk "custom OFS"             "a|b|c"         'BEGIN{OFS="|"} { print $1,$2,$3 }' \
    "a b c"

assert_awk "custom RS"              "2"             'BEGIN{RS=","} END{print NR}' \
    "a,b"

# ═════════════════════════════════════════════════════════════
section "2. Arithmetic & Variables"
# ═════════════════════════════════════════════════════════════

assert_awk "addition"               "7"             'BEGIN { print 3 + 4 }'
assert_awk "subtraction"            "5"             'BEGIN { print 9 - 4 }'
assert_awk "multiplication"         "12"            'BEGIN { print 3 * 4 }'
assert_awk "division"               "2.5"           'BEGIN { print 5 / 2 }'
assert_awk "modulo"                 "1"             'BEGIN { print 10 % 3 }'
assert_awk "exponentiation"         "8"             'BEGIN { print 2 ^ 3 }'
assert_awk "string concat"          "helloworld"    'BEGIN { a="hello"; b="world"; print a b }'
assert_awk "variable accumulate"    "15"            '{ sum += $1 } END { print sum }' \
    "1
2
3
4
5"
assert_awk "ternary operator"       "big"           'BEGIN { x=10; print (x>5) ? "big" : "small" }'

# ═════════════════════════════════════════════════════════════
section "3. String Functions"
# ═════════════════════════════════════════════════════════════

assert_awk "length()"               "5"             'BEGIN { print length("hello") }'
assert_awk "substr()"               "ell"           'BEGIN { print substr("hello", 2, 3) }'
assert_awk "index()"                "3"             'BEGIN { print index("hello", "llo") }'
assert_awk "split()"                "3"             'BEGIN { print split("a:b:c", arr, ":") }'
assert_awk "sub()"                  "hXllo"         'BEGIN { x="hello"; sub(/e/, "X", x); print x }'
assert_awk "gsub()"                 "hXllX"         'BEGIN { x="hello"; gsub(/[eo]/, "X", x); print x }'
assert_awk "toupper()"              "HELLO"         'BEGIN { print toupper("hello") }'
assert_awk "tolower()"              "hello"         'BEGIN { print tolower("HELLO") }'
assert_awk "sprintf()"              "042"           'BEGIN { print sprintf("%03d", 42) }'
assert_awk "match()"                "2"             'BEGIN { print match("hello", /e/) }'

# ═════════════════════════════════════════════════════════════
section "4. Control Flow"
# ═════════════════════════════════════════════════════════════

assert_awk "if-else true"           "yes"           'BEGIN { if (1) print "yes"; else print "no" }'
assert_awk "if-else false"          "no"            'BEGIN { if (0) print "yes"; else print "no" }'
assert_awk "while loop"             "0
1
2" \
    'BEGIN { i=0; while(i<3){ print i; i++ } }'

assert_awk "for loop"               "0
1
2" \
    'BEGIN { for(i=0;i<3;i++) print i }'

assert_awk "do-while"               "0
1
2" \
    'BEGIN { i=0; do { print i; i++ } while(i<3) }'

assert_awk "next skips record"      "1
3" \
    '{ if ($0==2) next; print }' \
    "1
2
3"

assert_awk "exit in BEGIN"          "bye"           'BEGIN { print "bye"; exit }'

# ═════════════════════════════════════════════════════════════
section "5. Arrays"
# ═════════════════════════════════════════════════════════════

assert_awk "basic array set/get"    "bar"           'BEGIN { a["foo"]="bar"; print a["foo"] }'
assert_awk "array length"           "3"             'BEGIN { a[1]=1;a[2]=2;a[3]=3; print length(a) }'
assert_awk "delete element"         "1"             'BEGIN { a[1]=1;a[2]=2; delete a[2]; print length(a) }'
assert_awk "in operator"            "yes"           'BEGIN { a["x"]=1; if ("x" in a) print "yes" }'
assert_awk "count occurrences"      "2"             '{ count[$1]++ } END { print count["a"] }' \
    "a
b
a"

# ═════════════════════════════════════════════════════════════
section "6. BEGIN / END / Patterns"
# ═════════════════════════════════════════════════════════════

assert_awk "BEGIN block"            "start"         'BEGIN { print "start" }'
assert_awk "END block"              "end"           'END { print "end" }' ""
assert_awk "pattern match"          "hello"         '/hello/ { print }' \
    "hello
world"

assert_awk "negation pattern"       "world"         '!/hello/ { print }' \
    "hello
world"

assert_awk "range pattern"          "2
3
4" \
    '/2/,/4/ { print }' \
    "1
2
3
4
5"

assert_awk "line count in END"      "3"             'END { print NR }' \
    "a
b
c"

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