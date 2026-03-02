#!/bin/bash

# ==========================================
# 1. Test Framework Setup
# ==========================================
tests_run=0
tests_passed=0
tests_failed=0

# Assertion for matching strings or numbers
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    
    tests_run=$((tests_run + 1))
    if [ "$expected" == "$actual" ]; then
        echo -e "✅ PASS: $message"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "❌ FAIL: $message\n   Expected: '$expected'\n   Got:      '$actual'"
        tests_failed=$((tests_failed + 1))
    fi
}

# Assertion for checking command exit codes
assert_exit_code() {
    local expected_code="$1"
    local actual_code="$2"
    local message="$3"
    
    tests_run=$((tests_run + 1))
    if [ "$expected_code" -eq "$actual_code" ]; then
        echo -e "✅ PASS: $message"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "❌ FAIL: $message\n   Expected exit code: $expected_code\n   Got:                $actual_code"
        tests_failed=$((tests_failed + 1))
    fi
}

# ==========================================
# 2. Your Tests
# ==========================================
echo "Running Bash Test Suite..."
echo "--------------------------------------"

# Test 1: Math Operations
result=$(( 10 * 5 ))
message="Multiplication should equal 50"
if [ "50" == "$result" ]; then
        echo -e "PASS: $message"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "FAIL: $message\n   Expected: '$expected'\n   Got:      '$actual'"
        tests_failed=$((tests_failed + 1))
    fi


# Test 2: String Slicing/Manipulation
str="Hello World"

message="String slicing should extract 'Hello'"
if [ "Hello" == "${str:0:5}" ]; then
        echo -e "PASS: $message"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "FAIL: $message\n   Expected: '$expected'\n   Got:      '$actual'"
        tests_failed=$((tests_failed + 1))
    fi



# Test 3: Exit Codes (Success)
bin/ls > /dev/null 2>&1

message="Standard commands should return 0 on success"
if [ $? == 0 ]; then
        echo -e "PASS: $message"
        tests_passed=$((tests_passed + 1))
    else
        echo -e "FAIL: $message\n   Expected: '$expected'\n   Got:      '$actual'"
        tests_failed=$((tests_failed + 1))
    fi

# Test 4: File Operations
bin/touch dummy_test_file.tmp
if [ -f "dummy_test_file.tmp" ]; then
    echo -e "PASS: Temporary file was created successfully"
    tests_passed=$((tests_passed + 1))
else
    echo -e "FAIL: Temporary file was not created successfully"
    tests_failed=$((tests_failed + 1))
fi
rm dummy_test_file.tmp

# ==========================================
# 3. Test Summary
# ==========================================
echo "--------------------------------------"
echo "Results: $tests_passed passed, $tests_failed failed out of $tests_run tests."

# Exit with 1 if any tests failed, 0 if all passed (useful for CI/CD pipelines)
if [ "$tests_failed" -gt 0 ]; then
    exit 1
else
    exit 0
fi
