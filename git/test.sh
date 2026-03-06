#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# git test suite for lind-wasm
#
# Tests git functionality through the Lind runtime using a local repository.
# No network access required — all tests use local operations.
#
# Usage:
#   ./git/test.sh
#
# Exit 0 on all pass, non-zero on any failure.
###############################################################################

PREFIX="[git-test]"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
LOG_FILE="${LOG_FILE:-/tmp/git_test_results.log}"

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LIND_RUN="$LIND_WASM_ROOT/scripts/lind_run"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
GIT_BIN="bin/git"
REPO_PATH="/tmp/git-test-repo"
HOST_REPO_PATH="$LINDFS_ROOT$REPO_PATH"

# --- cleanup -----------------------------------------------------------------
cleanup() {
    sudo rm -rf "$HOST_REPO_PATH" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- verify binary exists ----------------------------------------------------
if [[ ! -f "$LINDFS_ROOT/$GIT_BIN" ]]; then
    echo "$PREFIX ERROR: git binary not found at $LINDFS_ROOT/$GIT_BIN"
    exit 1
fi
echo "$PREFIX git binary found at: $LINDFS_ROOT/$GIT_BIN"

# --- ensure /dev/urandom and /dev/random exist in lindfs ---------------------
if [[ ! -e "$LINDFS_ROOT/dev/urandom" ]]; then
    sudo mknod "$LINDFS_ROOT/dev/urandom" c 1 9 2>/dev/null || true
    sudo chmod 666 "$LINDFS_ROOT/dev/urandom"
fi
if [[ ! -e "$LINDFS_ROOT/dev/random" ]]; then
    sudo mknod "$LINDFS_ROOT/dev/random" c 1 8 2>/dev/null || true
    sudo chmod 666 "$LINDFS_ROOT/dev/random"
fi

# --- ensure git templates exist in lindfs ------------------------------------
if [[ ! -d "$LINDFS_ROOT/usr/local/share/git-core/templates" ]]; then
    echo "$PREFIX copying git templates to lindfs..."
    sudo mkdir -p "$LINDFS_ROOT/usr/local/share/git-core"
    sudo cp -r "$APPS_ROOT/git/templates" "$LINDFS_ROOT/usr/local/share/git-core/templates"
fi

# --- prepare clean test repo -------------------------------------------------
cleanup
sudo mkdir -p "$HOST_REPO_PATH"

# --- test helpers ------------------------------------------------------------
run_test() {
    local name="$1"
    shift
    local test_output
    if test_output=$("$@" 2>&1); then
        echo "$PREFIX [PASS] $name"
        (( PASS_COUNT++ )) || true
    else
        echo "$PREFIX [FAIL] $name"
        if [[ -n "${test_output:-}" ]]; then
            echo "$PREFIX        output: $(echo "$test_output" | head -3)"
        fi
        (( FAIL_COUNT++ )) || true
        FAILURES+=("$name")
    fi
}

# Helper to run git inside the test repo
run_git() {
    $LIND_RUN "$GIT_BIN" -C "$REPO_PATH" "$@" 2>&1
}

# --- test cases --------------------------------------------------------------

# 1. Binary check
test_binary_exists() {
    [[ -f "$LINDFS_ROOT/$GIT_BIN" ]]
}

# 2. --version
test_version() {
    local output
    output=$($LIND_RUN "$GIT_BIN" --version 2>&1)
    [[ "$output" == *"git version"* ]]
}

# 3. --help
test_help() {
    local output
    output=$($LIND_RUN "$GIT_BIN" --help 2>&1)
    echo "$output" | grep -qi "usage"
}

# 4. git init
test_init() {
    local output
    output=$($LIND_RUN "$GIT_BIN" init "$REPO_PATH" 2>&1)
    [[ "$output" == *"Initialized empty Git repository"* ]]
}

# 5. git config user.name
test_config_name() {
    run_git config user.name "Test User"
    local output
    output=$(run_git config user.name)
    [[ "$output" == *"Test User"* ]]
}

# 6. git config user.email
test_config_email() {
    run_git config user.email "test@example.com"
    local output
    output=$(run_git config user.email)
    [[ "$output" == *"test@example.com"* ]]
}

# 7. git status on empty repo
test_status_empty() {
    local output
    output=$(run_git status)
    [[ "$output" == *"nothing to commit"* ]]
}

# 8. git add
test_add() {
    echo "hello world" | sudo tee "$HOST_REPO_PATH/file1.txt" > /dev/null
    local output
    output=$(run_git add file1.txt)
    # add produces no output on success, check status instead
    output=$(run_git status)
    [[ "$output" == *"new file"* ]] || [[ "$output" == *"Changes to be committed"* ]]
}

# 9. git commit
test_commit() {
    local output
    output=$(run_git commit -m "first commit")
    [[ "$output" == *"first commit"* ]]
}

# 10. git log
test_log() {
    local output
    output=$(run_git log --oneline)
    [[ "$output" == *"first commit"* ]]
}

# 11. git log --format
test_log_format() {
    local output
    output=$(run_git log --format="%H %s")
    [[ "$output" == *"first commit"* ]]
}

# 12. git status after commit (clean)
test_status_clean() {
    local output
    output=$(run_git status)
    [[ "$output" == *"nothing to commit"* ]]
}

# 13. git branch create
test_branch_create() {
    run_git branch test-branch
    local output
    output=$(run_git branch)
    [[ "$output" == *"test-branch"* ]]
}

# 14. git checkout branch
test_checkout_branch() {
    local output
    output=$(run_git checkout test-branch)
    [[ "$output" == *"Switched to branch"* ]]
}

# 15. git checkout master/main
test_checkout_master() {
    local output
    output=$(run_git checkout master)
    [[ "$output" == *"Switched to branch"* ]]
}

# 16. git tag
test_tag_create() {
    run_git tag v1.0
    local output
    output=$(run_git tag)
    [[ "$output" == *"v1.0"* ]]
}

# 17. git tag annotated
test_tag_annotated() {
    local output
    output=$(run_git tag -a v2.0 -m "version 2.0")
    output=$(run_git tag)
    [[ "$output" == *"v2.0"* ]]
}

# 18. git diff (modified file)
test_diff() {
    echo "added line" | sudo tee -a "$HOST_REPO_PATH/file1.txt" > /dev/null
    local output
    output=$(run_git diff)
    [[ "$output" == *"+added line"* ]]
}

# 19. git diff --stat
test_diff_stat() {
    local output
    output=$(run_git diff --stat)
    [[ "$output" == *"file1.txt"* ]]
}

# 20. git add + commit modified file
test_commit_modified() {
    run_git add file1.txt
    local output
    output=$(run_git commit -m "second commit")
    [[ "$output" == *"second commit"* ]]
}

# 21. git log multiple commits
test_log_multiple() {
    local output
    output=$(run_git log --oneline)
    local count
    count=$(echo "$output" | wc -l)
    [[ "$count" -ge 2 ]]
}

# 22. git show
test_show() {
    local output
    output=$(run_git show --stat HEAD)
    [[ "$output" == *"second commit"* ]]
}

# 23. git rm
test_rm() {
    echo "to be removed" | sudo tee "$HOST_REPO_PATH/removeme.txt" > /dev/null
    run_git add removeme.txt
    run_git commit -m "add removeme"
    local output
    output=$(run_git rm removeme.txt)
    [[ "$output" == *"rm 'removeme.txt'"* ]]
    run_git commit -m "removed removeme"
}

# 24. git mv
test_mv() {
    echo "movable" | sudo tee "$HOST_REPO_PATH/moveme.txt" > /dev/null
    run_git add moveme.txt
    run_git commit -m "add moveme"
    local output
    output=$(run_git mv moveme.txt moved.txt)
    # mv is silent on success, verify via status
    output=$(run_git status)
    [[ "$output" == *"renamed"* ]] || [[ "$output" == *"moved.txt"* ]]
    # Commit the rename so working tree is clean for merge
    run_git add -A
    run_git commit -m "renamed moveme to moved"
}

# 25. git merge
test_merge() {
    # Create a new branch from current HEAD
    run_git branch merge-branch
    run_git checkout merge-branch
    echo "merge content" | sudo tee "$HOST_REPO_PATH/merge-file.txt" > /dev/null
    run_git add merge-file.txt
    run_git commit -m "merge branch commit"
    # Switch back and merge
    run_git checkout master
    local output
    output=$(run_git merge merge-branch)
    [[ "$output" == *"merge branch commit"* ]] || [[ "$output" == *"Fast-forward"* ]] || [[ "$output" == *"Merge made"* ]]
}

# 26. git reset (soft)
test_reset_soft() {
    echo "reset me" | sudo tee "$HOST_REPO_PATH/resetfile.txt" > /dev/null
    run_git add resetfile.txt
    run_git commit -m "to be reset"
    local before after
    before=$(run_git rev-parse HEAD | tr -d '[:space:]')
    run_git reset --soft HEAD~1
    after=$(run_git rev-parse HEAD | tr -d '[:space:]')
    [[ "$before" != "$after" ]]
}

# 27. git rev-parse HEAD
test_rev_parse() {
    local output
    output=$(run_git rev-parse HEAD)
    # Should be a 40-char hex SHA
    [[ ${#output} -ge 40 ]]
}

# 28. git cat-file
test_cat_file() {
    local sha
    sha=$(run_git rev-parse HEAD | tr -d '[:space:]')
    local output
    output=$(run_git cat-file -t "$sha")
    [[ "$output" == *"commit"* ]]
}

# 29. git hash-object
test_hash_object() {
    echo "hash me" | sudo tee "$HOST_REPO_PATH/hashtest.txt" > /dev/null
    local output
    output=$(run_git hash-object "$REPO_PATH/hashtest.txt")
    [[ ${#output} -ge 40 ]]
}

# 30. git config --list
test_config_list() {
    local output
    output=$(run_git config --list)
    [[ "$output" == *"user.name=Test User"* ]]
}

# --- run tests ---------------------------------------------------------------

echo "" | tee "$LOG_FILE"
echo "$PREFIX === Running git tests ===" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Tests must run in order — later tests depend on earlier state
run_test "Binary exists at lindfs/bin/git"       test_binary_exists
run_test "git --version"                          test_version
run_test "git --help"                             test_help
run_test "git init"                               test_init
run_test "git config user.name"                   test_config_name
run_test "git config user.email"                  test_config_email
run_test "git status (empty repo)"                test_status_empty
run_test "git add"                                test_add
run_test "git commit"                             test_commit
run_test "git log"                                test_log
run_test "git log --format"                       test_log_format
run_test "git status (clean)"                     test_status_clean
run_test "git branch create"                      test_branch_create
run_test "git checkout branch"                    test_checkout_branch
run_test "git checkout master"                    test_checkout_master
run_test "git tag"                                test_tag_create
run_test "git tag annotated"                      test_tag_annotated
run_test "git diff"                               test_diff
run_test "git diff --stat"                        test_diff_stat
run_test "git commit modified file"               test_commit_modified
run_test "git log multiple commits"               test_log_multiple
run_test "git show"                               test_show
run_test "git rm"                                 test_rm
run_test "git mv"                                 test_mv
run_test "git merge"                              test_merge
run_test "git reset --soft"                       test_reset_soft
run_test "git rev-parse HEAD"                     test_rev_parse
run_test "git cat-file"                           test_cat_file
run_test "git hash-object"                        test_hash_object
run_test "git config --list"                      test_config_list

# --- report ------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo ""
echo "$PREFIX $PASS_COUNT/$TOTAL tests passed, $FAIL_COUNT failed"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "$PREFIX failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "$PREFIX   - $f"
    done
fi

echo "$PREFIX Log saved to: $LOG_FILE"

cleanup

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0