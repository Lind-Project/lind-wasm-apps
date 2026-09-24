#!/usr/bin/env bash
# Shared SKIP-tally helper for <app>/run_tests.sh (see TESTING.md, requirement 5).
#
# Source this from run_tests.sh:
#   source "$SCRIPT_DIR/../scripts/test_lib.sh"
#
# It only owns the SKIPPED counter and skip decision — each app keeps its own
# PASS/FAIL counters and pass()/fail()/assert() style untouched.
#
# Usage in a test loop:
#   if is_skipped "case-name"; then
#       log_skip "case-name" "reason"
#   else
#       ... run the test, call the app's own pass()/fail() ...
#   fi
#
# SKIP_TESTS="case-name other-case" ./run_tests.sh   # suppress specific cases

SKIPPED=0

is_skipped() {
    local name="$1"
    [[ " ${SKIP_TESTS:-} " == *" $name "* ]]
}

log_skip() {
    local name="$1"
    local reason="${2:-}"
    SKIPPED=$((SKIPPED + 1))
    if [[ -n "$reason" ]]; then
        echo "SKIP: $name ($reason)"
    else
        echo "SKIP: $name"
    fi
}
