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
SKIP_REASON=""

# Also honors GRATE_SKIP_LIST (exact names, loaded by grate_lib.sh from
# <app>/grate_skips/<grate>.txt) when the suite runs under a grate.
is_skipped() {
    local name="$1"
    local entry
    SKIP_REASON=""
    if [[ " ${SKIP_TESTS:-} " == *" $name "* ]]; then
        return 0
    fi
    for entry in ${GRATE_SKIP_LIST[@]+"${GRATE_SKIP_LIST[@]}"}; do
        if [[ "$entry" == "$name" ]]; then
            SKIP_REASON="known failure under grate ${GRATE_NAME:-}"
            return 0
        fi
    done
    return 1
}

log_skip() {
    local name="$1"
    local reason="${2:-$SKIP_REASON}"
    SKIPPED=$((SKIPPED + 1))
    if [[ -n "$reason" ]]; then
        echo "SKIP: $name ($reason)"
    else
        echo "SKIP: $name"
    fi
}
