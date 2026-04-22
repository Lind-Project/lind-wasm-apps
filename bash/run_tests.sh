#!/bin/bash
# ─────────────────────────────────────────────────────────────
# run-lind-tests.sh
# Custom bash test suite for Lind/wasm sandbox environment
# Usage: THIS_SH=/path/to/bash ./run-lind-tests.sh
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_ROOT="$APPS_ROOT/bash"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"

mkdir -p "$LINDFS_ROOT/tests/bash/"

PASS=0
FAIL=0
TOTAL=0
counter=1
TIMEOUT_SECS=3

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

assert() {
    local description="$1"
    local expected="$2"
    local cmd="$3"

    local testfile="tests/bash/test$counter.sh"

    local testfile_path="$LINDFS_ROOT/tests/bash/test$counter.sh"
    counter=$((counter + 1))
    # Print the running state first
    echo "RUNNING $description........"
    echo "$cmd" > "$testfile_path"
    
    # Evaluate the command
    local actual
    actual=$(timeout ${TIMEOUT_SECS}s lind_run --enable-fpcast --env PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:.  bin/bash  "$testfile" 2>/dev/null)
    echo "--------- Test run Completed -------"

    exit_code=$?

    TOTAL=$((TOTAL + 1))
    
    # Overwrite the running state with the final result
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC} $description                                "
        PASS=$((PASS + 1))
    else
	echo -e " ${RED} $testfile failed"
        echo -e "  ${RED}FAIL${NC} $description                                "
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
section "1. Variables"
# ─────────────────────────────────────────────────────────────

assert "simple assignment"            "hello"       'x=hello; echo $x'
assert "quoted value with spaces"     "hello world" 'x="hello world"; echo "$x"'
assert "unset var is empty"           ""            'echo "$UNSET_XYZ"'
assert "default :- when unset"        "default"     'echo "${X:-default}"'
assert "default :- when empty"        "default"     'x=""; echo "${x:-default}"'
assert "assign default :="            "assigned"    'echo "${x:=assigned}"'
assert "alternative :+ when set"      "alt"         'x=set; echo "${x:+alt}"'
assert "alternative :+ when unset"    ""            'echo "${X:+alt}"'
assert "variable length"              "5"           'x=hello; echo "${#x}"'
assert "readonly variable"            "42"          'readonly x=42; echo "$x"'
assert "export to subshell"           "visible"     'export V=visible; bash -c "echo $V"'
assert "local var in function"        "local
global" \
    'V=global; f(){ local V=local; echo "$V"; }; f; echo "$V"'

# ─────────────────────────────────────────────────────────────
section "2. Arithmetic"
# ─────────────────────────────────────────────────────────────

assert "addition"              "5"   'echo $((2 + 3))'
assert "subtraction"           "4"   'echo $((10 - 6))'
assert "multiplication"        "12"  'echo $((3 * 4))'
assert "integer division"      "3"   'echo $((10 / 3))'
assert "modulo"                "1"   'echo $((10 % 3))'
assert "exponentiation"        "8"   'echo $((2 ** 3))'
assert "increment ++"          "6"   'x=5; ((x++)); echo $x'
assert "decrement --"          "4"   'x=5; ((x--)); echo $x'
assert "bitwise AND"           "4"   'echo $((12 & 6))'
assert "bitwise OR"            "14"  'echo $((12 | 6))'
assert "left shift"            "8"   'echo $((1 << 3))'
assert "right shift"           "2"   'echo $((16 >> 3))'
assert "negative numbers"      "-3"  'echo $((5 - 8))'
assert "let builtin"           "10"  'let x=5+5; echo $x'
assert "arithmetic for loop"   "0
1
2
3
4" \
    'for ((i=0; i<5; i++)); do echo $i; done'

# ─────────────────────────────────────────────────────────────
section "3. Strings"
# ─────────────────────────────────────────────────────────────

assert "concatenation"           "helloworld"    'a=hello; b=world; echo "${a}${b}"'
assert "substring from offset"   "ello"          'x=hello; echo "${x:1}"'
assert "substring with length"   "ell"           'x=hello; echo "${x:1:3}"'
assert "strip prefix #"          "world"         'x=hello_world; echo "${x#*_}"'
assert "strip greedy prefix ##"  "txt"           'x=path/to/file.txt; echo "${x##*.}"'
assert "strip suffix %"          "path/to/file"  'x=path/to/file.txt; echo "${x%.*}"'
assert "strip greedy suffix %%"  "path"          'x=path/to/file.txt; echo "${x%%/*}"'
assert "replace first"           "hXllo"         'x=hello; echo "${x/e/X}"'
assert "replace all"             "hXllX"         'x=hello; echo "${x//[eo]/X}"'
assert "uppercase first ^"       "Hello"         'x=hello; echo "${x^}"'
assert "uppercase all ^^"        "HELLO"         'x=hello; echo "${x^^}"'
assert "lowercase first ,"       "hELLO"         'x=HELLO; echo "${x,}"'
assert "lowercase all ,,"        "hello"         'x=HELLO; echo "${x,,}"'

# ─────────────────────────────────────────────────────────────
section "4. Arrays"
# ─────────────────────────────────────────────────────────────

assert "index 0"             "one"         'a=(one two three); echo "${a[0]}"'
assert "index 1"             "two"         'a=(one two three); echo "${a[1]}"'
assert "all elements @"      "one two three" 'a=(one two three); echo "${a[@]}"'
assert "length"              "3"           'a=(one two three); echo "${#a[@]}"'
assert "append +="           "4"           'a=(one two three); a+=(four); echo "${#a[@]}"'
assert "slice"               "two three"   'a=(one two three four); echo "${a[@]:1:2}"'
assert "unset element"       "one three"   'a=(one two three); unset a[1]; echo "${a[@]}"'
assert "indices !@"          "0 1 2"       'a=(one two three); echo "${!a[@]}"'
assert "element length"      "5"           'a=(hello world); echo "${#a[0]}"'
assert "assoc array"         "bar"         'declare -A m; m[foo]=bar; echo "${m[foo]}"'
assert "assoc array length"  "1"           'declare -A m; m[k]=v; echo "${#m[@]}"'
assert "for loop over array" "one
two
three" \
    'a=(one two three); for i in "${a[@]}"; do echo "$i"; done'

# ─────────────────────────────────────────────────────────────
section "5. Control Flow"
# ─────────────────────────────────────────────────────────────

assert "if true"        "yes"    'if true; then echo yes; fi'
assert "if false else"  "no"     'if false; then echo yes; else echo no; fi'
assert "elif"           "middle" 'x=5; if [ $x -lt 3 ]; then echo low; elif [ $x -lt 8 ]; then echo middle; else echo high; fi'
assert "for list"       "1
2
3" \
    'for i in 1 2 3; do echo $i; done'
assert "for range"      "1
2
3" \
    'for i in {1..3}; do echo $i; done'
assert "while"          "0
1
2" \
    'i=0; while [ $i -lt 3 ]; do echo $i; i=$((i+1)); done'
assert "until"          "0
1
2" \
    'i=0; until [ $i -ge 3 ]; do echo $i; i=$((i+1)); done'
assert "break"          "0
1" \
    'for i in 0 1 2 3; do [ $i -eq 2 ] && break; echo $i; done'
assert "continue"       "0
1
3" \
    'for i in 0 1 2 3; do [ $i -eq 2 ] && continue; echo $i; done'
assert "case match"     "two"    'x=2; case $x in 1) echo one;; 2) echo two;; *) echo other;; esac'
assert "case wildcard"  "other"  'x=99; case $x in 1) echo one;; 2) echo two;; *) echo other;; esac'
assert "case pattern"   "letter" 'x=a; case $x in [0-9]) echo digit;; [a-z]) echo letter;; esac'
assert "break 2"        "0,0"    'for i in 0 1; do for j in 0 1; do echo "$i,$j"; break 2; done; done'
assert "nested loops"   "0,0
0,1
1,0
1,1" \
    'for i in 0 1; do for j in 0 1; do echo "$i,$j"; done; done'

# ─────────────────────────────────────────────────────────────
section "6. Functions"
# ─────────────────────────────────────────────────────────────

assert "basic call"            "hello"    'f(){ echo hello; }; f'
assert "with arguments"        "hello world" 'f(){ echo "$1 $2"; }; f hello world'
assert "return value"          "42"       'f(){ return 42; }; f; echo $?'
assert "output capture"        "computed" 'f(){ echo computed; }; r=$(f); echo "$r"'
assert "recursive factorial"   "120"      'f(){ [ $1 -le 1 ] && echo 1 || echo $(($1 * $(f $(($1-1))))); }; f 5'
assert "sees global"           "global"   'V=global; f(){ echo "$V"; }; f'
assert "modifies global"       "modified" 'V=orig; f(){ V=modified; }; f; echo "$V"'
assert "local does not leak"   "original" 'V=original; f(){ local V=x; }; f; echo "$V"'
assert "default arg"           "default"  'f(){ echo "${1:-default}"; }; f'
assert "\$@ variadic"          "a b c"    'f(){ echo "$@"; }; f a b c'
assert "\$# arg count"         "3"        'f(){ echo $#; }; f a b c'
assert "calls another function" "inner"   'inner(){ echo inner; }; outer(){ inner; }; outer'

# ─────────────────────────────────────────────────────────────
section "7. Redirection"
# ─────────────────────────────────────────────────────────────

TMPFILE=$(mktemp)
assert "stdout to file"        "hello"   "echo hello > $TMPFILE; cat $TMPFILE"
assert "append >>"             "line1
line2" \
    "echo line1 > $TMPFILE; echo line2 >> $TMPFILE; cat $TMPFILE"
assert "stderr to file"        "err"     "echo err >&2 2>$TMPFILE; cat $TMPFILE"
assert "stdin from file"       "hello"   "echo hello > $TMPFILE; read l < $TMPFILE; echo \$l"
assert "heredoc"               "hello world" $'cat <<EOF\nhello world\nEOF'
assert "heredoc var expansion" "hello bash"  $'name=bash; cat <<EOF\nhello $name\nEOF'
assert "heredoc no expansion"  'hello $name' "cat <<'EOF'"$'\nhello $name\nEOF'
assert "herestring"            "hello"   'read x <<< hello; echo $x'
assert "pipe basic"            "HELLO"   'echo hello | tr a-z A-Z'
assert "pipe chain"            "3"       'printf "a\nb\nc\n" | wc -l | tr -d " "'
assert "process substitution"  "hello"   'cat <(echo hello)'
rm -f "$TMPFILE"

# ─────────────────────────────────────────────────────────────
section "8. Builtins"
# ─────────────────────────────────────────────────────────────

assert "echo basic"            "hello"       'echo hello'
assert "echo -n"               "hello"       'echo -n hello'
assert "echo -e tab"           "hello	world" 'echo -e "hello\tworld"'
assert "printf %s"             "hello"       'printf "%s\n" hello'
assert "printf %03d"           "042"         'printf "%03d\n" 42'
assert "printf %.2f"           "3.14"        'printf "%.2f\n" 3.14159'
assert "read herestring"       "hello world" 'read x y <<< "hello world"; echo "$x $y"'
assert "read -a array"         "one two three" 'read -a a <<< "one two three"; echo "${a[@]}"'
assert "cd and pwd"            "1"           'cd /tmp && [ "$(pwd)" = "/tmp" ] && echo 1'
assert "type builtin"          "1"           'type echo | grep -q builtin && echo 1'
assert "declare -i integer"    "0"           'declare -i x; x=abc; echo $x'
assert "declare -r readonly"   "1"           'declare -r x=1; echo $x'
assert "unset variable"        ""            'x=set; unset x; echo "$x"'
assert "shift"                 "b c"         'f(){ shift; echo "$@"; }; f a b c'
assert "set --"                "a b c"       'set -- a b c; echo "$@"'
assert "eval"                  "hello"       'eval "echo hello"'
assert "source a file"         "sourced"     'f=$(mktemp); echo "echo sourced" > $f; source $f; rm $f'

# ─────────────────────────────────────────────────────────────
section "9. Conditionals"
# ─────────────────────────────────────────────────────────────

assert "[ = ] string equal"    "yes" '[ "abc" = "abc" ] && echo yes'
assert "[ != ] string not eq"  "yes" '[ "abc" != "def" ] && echo yes'
assert "[ -z ] empty"          "yes" '[ -z "" ] && echo yes'
assert "[ -n ] not empty"      "yes" '[ -n "hi" ] && echo yes'
assert "[ -eq ]"               "yes" '[ 5 -eq 5 ] && echo yes'
assert "[ -ne ]"               "yes" '[ 5 -ne 6 ] && echo yes'
assert "[ -lt ]"               "yes" '[ 3 -lt 5 ] && echo yes'
assert "[ -gt ]"               "yes" '[ 5 -gt 3 ] && echo yes'
assert "[ -le ]"               "yes" '[ 5 -le 5 ] && echo yes'
assert "[ -ge ]"               "yes" '[ 5 -ge 5 ] && echo yes'
assert "[ -f ] file"           "yes" 'touch /tmp/hostname; [ -f /tmp/hostname ] && echo yes || echo no; rm /tmp/hostname'
assert "[ -d ] directory"      "yes" '[ -d /tmp ] && echo yes'
assert "[ -e ] exists"         "yes" '[ -e /tmp ] && echo yes'
assert "[[ =~ regex ]]"        "yes" '[[ "hello123" =~ [0-9]+ ]] && echo yes'
assert "[[ < string cmp ]]"    "yes" '[[ "abc" < "def" ]] && echo yes'
assert "&& short circuit"      "yes" 'true && echo yes'
assert "|| fallback"           "yes" 'false || echo yes'
assert "! negation"            "yes" '! false && echo yes'

# ─────────────────────────────────────────────────────────────
section "10. Command Substitution & Subshells"
# ─────────────────────────────────────────────────────────────

assert "\$() substitution"          "hello"    'x=$(echo hello); echo $x'
assert "backtick substitution"      "hello"    'x=`echo hello`; echo $x'
assert "nested substitution"        "4"        'echo $(echo $(( 2 + 2 )))'
assert "subshell isolation"         "original" 'x=original; (x=changed); echo $x'
assert "subshell inherits vars"     "inherited" 'x=inherited; (echo $x)'
assert "trailing newline trimmed"   "1"        'x=$(printf "hello\n\n"); [ "$x" = "hello" ] && echo 1'
assert "\$? true = 0"               "0"        'true; echo $?'
assert "\$? false = 1"              "1"        'false; echo $?'
assert "PIPESTATUS[0]"              "0"        'echo hi | cat >/dev/null; echo ${PIPESTATUS[0]}'

# ─────────────────────────────────────────────────────────────
section "11. Brace Expansion"
# ─────────────────────────────────────────────────────────────

assert "basic {a,b,c}"     "a b c"          'echo {a,b,c}'
assert "prefix x{a,b,c}"   "xa xb xc"       'echo x{a,b,c}'
assert "suffix {a,b,c}x"   "ax bx cx"       'echo {a,b,c}x'
assert "numeric {1..5}"    "1 2 3 4 5"      'echo {1..5}'
assert "alpha {a..e}"      "a b c d e"      'echo {a..e}'
assert "step {0..10..2}"   "0 2 4 6 8 10"   'echo {0..10..2}'
assert "nested {a,b}{1,2}" "a1 a2 b1 b2"    'echo {a,b}{1,2}'

# ─────────────────────────────────────────────────────────────
section "12. Glob & Pattern Matching"
# ─────────────────────────────────────────────────────────────

assert "case * glob"          "matched" 'x=hello; case $x in h*) echo matched;; esac'
assert "case ? glob"          "matched" 'x=hi; case $x in h?) echo matched;; esac'
assert "case [abc] class"     "matched" 'x=b; case $x in [abc]) echo matched;; esac'
assert "extglob +(a)"         "matched" 'shopt -s extglob; 
x=aaa; case $x in +(a)) echo matched;; esac'
assert "extglob *(a) empty"   "matched" 'shopt -s extglob; 
x=""; case $x in *(a)) echo matched;; esac'
assert "extglob ?(a)"         "matched" 'shopt -s extglob; 
x=a; case $x in ?(a)) echo matched;; esac'
assert "extglob @(cat|dog)"   "matched" 'shopt -s extglob; 
x=cat; case $x in @(cat|dog)) echo matched;; esac'
assert "extglob !(cat)"       "matched" 'shopt -s extglob; 
x=dog; case $x in !(cat)) echo matched;; esac'

# ─────────────────────────────────────────────────────────────
section "13. Special Variables"
# ─────────────────────────────────────────────────────────────

assert "\$0 is set"               "1" '[ -n "$0" ] && echo 1'
assert "\$\$ is numeric"          "1" '[[ $$ =~ ^[0-9]+$ ]] && echo 1'
assert "\$? true"                 "0" 'true; echo $?'
assert "\$? false"                "1" 'false; echo $?'
assert "\$# arg count"            "3" 'f(){ echo $#; }; f a b c'
assert "\$@ all args"             "a b c" 'f(){ echo "$@"; }; f a b c'
assert "\$* all args"             "a b c" 'f(){ echo "$*"; }; f a b c'
assert "RANDOM is numeric"        "1" '[[ $RANDOM =~ ^[0-9]+$ ]] && echo 1'
assert "LINENO is numeric"        "1" '[[ $LINENO =~ ^[0-9]+$ ]] && echo 1'
assert "BASH_VERSION is set"      "1" '[ -n "$BASH_VERSION" ] && echo 1'
assert "BASH_SUBSHELL in subshell" "1" '(echo $BASH_SUBSHELL)'
assert "IFS splits on space"      "3" 'x="a b c"; set -- $x; echo $#'
assert "PWD is set"               "1" '[ -n "$PWD" ] && echo 1'
assert "HOME is set"              "1" '[ -n "$HOME" ] && echo 1'

# ─────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────
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

COREUTIL_BINARIES=(
    "cat"
    "tr"
    "wc"
    "grep"
    "mktemp"
    "source"
    "rm"
    "touch"
)

for file in "${COREUTIL_BINARIES[@]}"; do
    # Construct the full path
    FULL_PATH="$LINDFS_ROOT/bin/$file"
    if [[ ! -f "$FULL_PATH" ]]; then
        echo -e "[ ${RED}MISSING${NC} ] $FULL_PATH"
        echo -r "Coreutils have to be built and copied to lindfs to run bash tests"
        echo "Tests 79,80,81, 84, 85, 89, 133 requires cat"
        echo "Tests 87 and 88 require tr"
	echo "Test 88 requires wc"
	echo "Test 99 requires grep"
	echo "Test 106 requires mktemp, source and rm"
	echo "Test 117 requires touch and rm"
	exit 1
    fi
done

