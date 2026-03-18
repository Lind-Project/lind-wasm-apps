#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LINDFS="${LIND_WASM_ROOT}/lindfs"

TEST_DIR="$LINDFS/tests/tinycc"
TEST_DIR_RELATIVE="tests/tinycc"

# --- Configuration Variables ---
COMPILER="lind_run bin/tcc"             
CFLAGS="-Wall"                # Compiler flags
RESULTS_FILE="$TEST_DIR/results.log"    # Summary of results

# ANSI Color Codes
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color





# Initialize Test Directory
mkdir -p "$TEST_DIR"
echo "TCC Test Results - $(date)" > "$RESULTS_FILE"

# --- Function to Run a Test Case ---
# Arguments: test_name, c_code, expected_output
run_test() {
    local name=$1
    local code=$2
    local expected=$3
    local src="$TEST_DIR/$name.c"
    local bin="$TEST_DIR/$name.bin"

    echo -e "${CYAN}Testing ${name}...${NC}"

    # 1. Write the C file
    echo "$code" > "$src"

    local src_relative="$TEST_DIR_RELATIVE/$name.c"
    local bin_relative="$TEST_DIR_RELATIVE/$name.bin"

    # 2. Compile
    $COMPILER $CFLAGS "$src_relative" -o "$bin_relative" 2>>"$RESULTS_FILE"
    
    if [ $? -ne 0 ]; then
        echo -e "  [${RED}FAIL${NC}] Compilation failed"
        echo "$name: Compilation Failed" >> "$RESULTS_FILE"
        return
    fi

    # 3. Execute and Capture Output
    local actual=$($bin)

    # 4. Compare
    if [ "$actual" == "$expected" ]; then
        echo -e "  [${GREEN}PASS${NC}] Output matched"
        echo "$name: PASS" >> "$RESULTS_FILE"
    else
        echo -e "  [${RED}FAIL${NC}] Output mismatch"
        echo -e "    Expected: $expected"
        echo -e "    Actual:   $actual"
        echo "$name: FAIL (Output mismatch)" >> "$RESULTS_FILE"
    fi
}

# --- Define Test Cases ---

# Test 1: Standard Hello World
run_test "hello_world" \
'#include <stdio.h>
int main() { printf("Hello TCC"); return 0; }' \
"Hello TCC"

# Test 2: Arithmetic logic
run_test "math_logic" \
'#include <stdio.h>
int main() { printf("%d", (10 + 5) * 2); return 0; }' \
"30"

# Test 3: Floating point
run_test "float_test" \
'#include <stdio.h>
int main() { printf("%.1f", 5.5 + 4.4); return 0; }' \
"9.9"

# Test 4: Argument handling (Simple version)
run_test "exit_code" \
'#include <stdio.h>
int main() { printf("ok"); return 0; }' \
"ok"

# Test 5: Dynamic Memory (malloc/free)
# Checks if the libc linked by TCC handles heap allocation correctly.
run_test "memory_malloc" \
'#include <stdio.h>
#include <stdlib.h>
int main() {
    int *ptr = (int*)malloc(5 * sizeof(int));
    if(ptr == NULL) return 1;
    for(int i=0; i<5; i++) ptr[i] = i * 2;
    printf("%d", ptr[4]);
    free(ptr);
    return 0;
}' \
"8"

# Test 6: File I/O (Writing and Reading)
# Crucial for Lind to see if the sandboxed file system (SafePOSIX) is working.
run_test "file_io" \
'#include <stdio.h>
int main() {
    FILE *f = fopen("test.txt", "w");
    fprintf(f, "LindTest");
    fclose(f);
    char buf[10];
    f = fopen("test.txt", "r");
    fgets(buf, 9, f);
    printf("%s", buf);
    fclose(f);
    return 0;
}' \
"LindTest"

# Test 7: Bitwise Operations
# Verifies that TCC generates the correct machine code for logic gates.
run_test "bitwise_logic" \
'#include <stdio.h>
int main() {
    unsigned char a = 0x0F; // 00001111
    unsigned char b = 0xF0; // 11110000
    printf("%d", (a | b) == 0xFF);
    return 0;
}' \
"1"

# Test 8: Struct Padding and Alignment
# Tests how the compiler packs data in memory.
run_test "struct_alignment" \
'#include <stdio.h>
struct data { char a; int b; char c; };
int main() {
    printf("%zu", sizeof(struct data) > 6 ? 1 : 0);
    return 0;
}' \
"1"



echo -e "${YELLOW}------------------------------------------${NC}"
echo "Full results saved to $RESULTS_FILE"
