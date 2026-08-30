#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# postgres test suite for lind-wasm (see TESTING.md)
#
# Tier 1 (default): smoke tests — initdb, server startup, basic SQL, text
#                   search, plpgsql, clean shutdown.
# Tier 2 (opt-in):  PG_REGRESS=1 ./postgres/run_tests.sh
#                   Runs the full pg_regress serial schedule and compares the
#                   failing-test list against postgres/regress_known_failures.txt.
#                   Only NEW failures (not in the baseline) fail the suite.
#
# Notes:
#   - postgres is a dylink-only app (plpgsql.so / dict_snowball.so / regress.so
#     require LIND_DYLINK=1, which is the Makefile default). There is no static
#     build variant to exercise.
#   - Every invocation goes through lind_run with --enable-fpcast; the wrapper
#     preloads libc.cwasm/libm.cwasm and self-sudos.
#
# Usage:
#   ./postgres/run_tests.sh                       # smoke tests
#   PG_REGRESS=1 ./postgres/run_tests.sh          # smoke + full regress
#   SKIP_TESTS="plpgsql function" ./postgres/run_tests.sh
###############################################################################

PREFIX="[postgres-test]"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
LOG_FILE="${LOG_FILE:-/tmp/postgres_test_results.log}"

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi
LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"

source "$SCRIPT_DIR/../scripts/test_lib.sh"

# --- configurable settings ---------------------------------------------------
PG_REGRESS="${PG_REGRESS:-0}"
TEST_PORT="${TEST_PORT:-5432}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-90}"      # seconds to wait for server ready
INITDB_TIMEOUT="${INITDB_TIMEOUT:-300}"       # initdb under wasm is slow
SQL_TIMEOUT="${SQL_TIMEOUT:-60}"              # per psql invocation
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-30}"
REGRESS_TIMEOUT="${REGRESS_TIMEOUT:-1800}"    # full serial schedule (~10 min healthy)

# Lind-internal paths (chroot-relative)
PGDATA="/tmp/pgdata-test"
SOCK_DIR="/tmp"
# Host-side views of the same paths
HOST_PGDATA="$LINDFS_ROOT$PGDATA"
HOST_SOCK="$LINDFS_ROOT$SOCK_DIR/.s.PGSQL.$TEST_PORT"

BASELINE_FILE="$SCRIPT_DIR/regress_known_failures.txt"
SKIP_FILE="$SCRIPT_DIR/regress_skip_tests.txt"
SCHEDULE="/regress/lind_schedule"                 # generated, hang-list applied
HOST_SCHEDULE="$LINDFS_ROOT$SCHEDULE"
SAVED_DIFFS="${SAVED_DIFFS:-/tmp/postgres-regression.diffs}"
SAVED_OUT="${SAVED_OUT:-/tmp/postgres-regression.out}"
REGRESS_LOG="/tmp/postgres-regress.$$.log"
SERVER_LOG="/tmp/postgres-server.$$.log"
SERVER_PID=""

# Server settings required under lind-wasm (see postgres/README.md history):
# sysv shared memory breaks lind exec, async I/O hangs, background workers
# crash on DSA — everything single-process, synchronous.
SERVER_OPTS=(
    -c max_parallel_workers=0
    -c max_parallel_workers_per_gather=0
    -c io_method=sync
    -c dynamic_shared_memory_type=mmap
    -c max_logical_replication_workers=0
    -c max_worker_processes=0
    -c autovacuum=off
    -c listen_addresses=
    -c unix_socket_directories="$SOCK_DIR"
    -c port="$TEST_PORT"
)

# --- cleanup -----------------------------------------------------------------
cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        sudo kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
    sudo rm -rf "$HOST_PGDATA" 2>/dev/null || true
    sudo rm -f "$HOST_SOCK"* 2>/dev/null || true
    # pg_regress writes results/ + regression.{out,diffs} into the installed
    # /regress tree; drop them so a re-run starts clean. On failure the diffs
    # were already copied to $SAVED_DIFFS.
    sudo rm -rf "$LINDFS_ROOT/regress/results" 2>/dev/null || true
    sudo rm -f "$LINDFS_ROOT/regress/regression.out" \
               "$LINDFS_ROOT/regress/regression.diffs" "$HOST_SCHEDULE" 2>/dev/null || true
    rm -f "$SERVER_LOG" "$REGRESS_LOG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- preconditions (fail fast, before any counter starts) --------------------
if [[ ! -x "$LIND_RUN" ]]; then
    echo "$PREFIX ERROR: lind_run not found at $LIND_RUN"
    echo "$PREFIX        set LIND_WASM_ROOT or use the conventional sibling layout"
    exit 1
fi
if [[ ! -f "$APPS_ROOT/build/postgres/bin/postgres.cwasm" ]]; then
    echo "$PREFIX ERROR: postgres not staged at build/postgres/bin/postgres.cwasm"
    echo "$PREFIX        fix: make postgres"
    exit 1
fi
for bin in initdb postgres psql; do
    if [[ ! -f "$LINDFS_ROOT/bin/$bin.cwasm" ]]; then
        echo "$PREFIX ERROR: $bin.cwasm not installed in $LINDFS_ROOT/bin"
        echo "$PREFIX        fix: make install-postgres"
        exit 1
    fi
done
if [[ "$PG_REGRESS" == "1" ]]; then
    if [[ ! -f "$LINDFS_ROOT/bin/pg_regress.cwasm" ]]; then
        echo "$PREFIX ERROR: pg_regress.cwasm not installed in $LINDFS_ROOT/bin"
        echo "$PREFIX        fix: make postgres && make install-postgres"
        exit 1
    fi
    if [[ ! -f "$LINDFS_ROOT/regress/serial_schedule" ]]; then
        echo "$PREFIX ERROR: regress inputs not installed at $LINDFS_ROOT/regress"
        echo "$PREFIX        fix: make postgres && make install-postgres"
        exit 1
    fi
fi
echo "$PREFIX binaries found in $LINDFS_ROOT/bin"

# stale state from a previous crashed run
sudo rm -rf "$HOST_PGDATA" 2>/dev/null || true
sudo rm -f "$HOST_SOCK"* 2>/dev/null || true

# --- helpers -----------------------------------------------------------------
run_psql() {
    # run_psql <database> <sql>
    local db="$1" sql="$2"
    timeout "$SQL_TIMEOUT" "$LIND_RUN" --enable-fpcast /bin/psql.cwasm \
        -h "$SOCK_DIR" -p "$TEST_PORT" -d "$db" -v ON_ERROR_STOP=1 -tA -c "$sql"
}

run_test() {
    local name="$1"
    shift
    if is_skipped "$name"; then
        echo "$PREFIX SKIP: $name" | tee -a "$LOG_FILE"
        log_skip "$name" >/dev/null
        return
    fi
    local test_output
    if test_output=$("$@" 2>&1); then
        echo "$PREFIX PASS: $name" | tee -a "$LOG_FILE"
        (( PASS_COUNT++ )) || true
    else
        echo "$PREFIX FAIL: $name" | tee -a "$LOG_FILE"
        if [[ -n "${test_output:-}" ]]; then
            echo "$PREFIX        output: $(echo "$test_output" | tail -3)" | tee -a "$LOG_FILE"
        fi
        (( FAIL_COUNT++ )) || true
        FAILURES+=("$name")
    fi
}

: > "$LOG_FILE"
{ echo ""; echo "$PREFIX === Running postgres tests ==="; echo ""; } | tee -a "$LOG_FILE"

# --- setup step 1: initdb ----------------------------------------------------
# initdb and server startup are counted as tests, but a failure here makes
# every SQL test meaningless, so we stop the suite (exit 1) instead of
# accumulating timeout failures against a dead server.
setup_failed() {
    local name="$1"
    echo "$PREFIX FAIL: $name" | tee -a "$LOG_FILE"
    (( FAIL_COUNT++ )) || true
    FAILURES+=("$name")
    echo "$PREFIX --- server log ---"
    cat "$SERVER_LOG" 2>/dev/null || true
    echo "$PREFIX $PASS_COUNT passed, $FAIL_COUNT failed (suite aborted: $name)" | tee -a "$LOG_FILE"
    exit 1
}

echo "$PREFIX running initdb..."
if timeout "$INITDB_TIMEOUT" "$LIND_RUN" --enable-fpcast /bin/initdb.cwasm \
        -D "$PGDATA" --no-locale >"$SERVER_LOG" 2>&1 \
        && sudo test -f "$HOST_PGDATA/PG_VERSION"; then
    echo "$PREFIX PASS: initdb creates cluster" | tee -a "$LOG_FILE"
    (( PASS_COUNT++ )) || true
else
    setup_failed "initdb creates cluster"
fi

# --- setup step 2: server startup --------------------------------------------
echo "$PREFIX starting postgres server..."
setsid "$LIND_RUN" --enable-fpcast /bin/postgres.cwasm -D "$PGDATA" \
    "${SERVER_OPTS[@]}" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=false
for (( i=0; i<STARTUP_TIMEOUT; i++ )); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        break
    fi
    if run_psql postgres "SELECT 1;" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done
if $READY; then
    echo "$PREFIX PASS: server becomes ready" | tee -a "$LOG_FILE"
    (( PASS_COUNT++ )) || true
else
    setup_failed "server becomes ready"
fi

# --- test cases --------------------------------------------------------------
test_select_one() {
    local out
    out="$(run_psql postgres "SELECT 1;")"
    [[ "$out" == "1" ]] || { echo "expected 1, got '$out'" >&2; return 1; }
}

test_table_roundtrip() {
    run_psql postgres "DROP TABLE IF EXISTS lind_smoke; CREATE TABLE lind_smoke(id int, val text);" >/dev/null
    run_psql postgres "INSERT INTO lind_smoke VALUES (1,'alpha'),(2,'beta'),(3,'gamma');" >/dev/null
    local out
    out="$(run_psql postgres "SELECT count(*) FROM lind_smoke WHERE id >= 2;")"
    run_psql postgres "DROP TABLE lind_smoke;" >/dev/null
    [[ "$out" == "2" ]] || { echo "expected count 2, got '$out'" >&2; return 1; }
}

test_transaction_rollback() {
    run_psql postgres "DROP TABLE IF EXISTS lind_txn; CREATE TABLE lind_txn(id int);" >/dev/null
    run_psql postgres "BEGIN; INSERT INTO lind_txn VALUES (1); ROLLBACK;" >/dev/null
    local out
    out="$(run_psql postgres "SELECT count(*) FROM lind_txn;")"
    run_psql postgres "DROP TABLE lind_txn;" >/dev/null
    [[ "$out" == "0" ]] || { echo "rollback leaked rows: count=$out" >&2; return 1; }
}

test_text_search() {
    # exercises dict_snowball.so + tsearch_data staging
    local out
    out="$(run_psql postgres "SELECT to_tsvector('english', 'the quick brown fox');")"
    [[ "$out" == "'brown':3 'fox':4 'quick':2" ]] \
        || { echo "unexpected tsvector: '$out'" >&2; return 1; }
}

test_plpgsql() {
    # exercises dlopen of plpgsql.so from /lib
    run_psql postgres "CREATE OR REPLACE FUNCTION lind_add(a int, b int) RETURNS int AS \$\$ BEGIN RETURN a + b; END; \$\$ LANGUAGE plpgsql;" >/dev/null
    local out
    out="$(run_psql postgres "SELECT lind_add(19, 23);")"
    run_psql postgres "DROP FUNCTION lind_add(int, int);" >/dev/null
    [[ "$out" == "42" ]] || { echo "expected 42, got '$out'" >&2; return 1; }
}

run_test "connectivity (SELECT 1)"      test_select_one
run_test "table create/insert/select"   test_table_roundtrip
run_test "transaction rollback"         test_transaction_rollback
run_test "text search (snowball)"       test_text_search
run_test "plpgsql function"             test_plpgsql

# --- tier 2: pg_regress ------------------------------------------------------
build_filtered_schedule() {
    # Write a copy of serial_schedule with the hang-listed tests removed, so a
    # single hanging test can't consume the whole REGRESS_TIMEOUT. Each removed
    # test is reported through the shared SKIPPED tally (TESTING.md req. 5).
    local skipped_names=()
    local name
    if [[ -f "$SKIP_FILE" ]]; then
        # `|| [[ -n "$name" ]]` so a final line without a trailing newline
        # is still processed.
        while read -r name || [[ -n "$name" ]]; do
            name="${name%%[[:space:]]*}"
            [[ -z "$name" || "$name" == \#* ]] && continue
            skipped_names+=("$name")
        done < "$SKIP_FILE"
    fi

    if [[ ${#skipped_names[@]} -eq 0 ]]; then
        sudo cp "$LINDFS_ROOT/regress/serial_schedule" "$HOST_SCHEDULE"
        return
    fi

    local pattern
    pattern="$(printf '%s\n' "${skipped_names[@]}" | paste -sd'|' -)"
    sudo rm -f "$HOST_SCHEDULE"
    grep -vE "^test: (${pattern})[[:space:]]*$" \
        "$LINDFS_ROOT/regress/serial_schedule" | sudo tee "$HOST_SCHEDULE" >/dev/null

    for name in "${skipped_names[@]}"; do
        echo "$PREFIX SKIP: regress/$name (hang-listed)" | tee -a "$LOG_FILE"
        log_skip "regress/$name" >/dev/null
    done
}

run_regress() {
    run_psql postgres "DROP DATABASE IF EXISTS regression;" >/dev/null 2>&1 || true
    run_psql postgres "CREATE DATABASE regression;" >/dev/null

    # Capture the failing-test list and diff it against the known-failures
    # baseline. Only failures absent from the baseline fail the suite; baseline
    # entries that now pass are reported so the file gets pruned.
    # pg_regress output is TAP ("not ok 12   - char   123 ms") on PG >= 16 and
    # "test char ... FAILED" on older versions; handle both.
    timeout "$REGRESS_TIMEOUT" "$LIND_RUN" --enable-fpcast /bin/pg_regress.cwasm \
        --use-existing --host="$SOCK_DIR" --port="$TEST_PORT" \
        --bindir=/bin --inputdir=/regress --expecteddir=/regress \
        --outputdir=/regress --dlpath=/lib \
        --schedule="$SCHEDULE" --max-concurrent-tests=1 \
        >"$REGRESS_LOG" 2>&1 || true

    # Preserve the run artifacts outside lindfs before cleanup removes them;
    # $SAVED_OUT is the per-test result list a baseline refresh is seeded from.
    sudo cp "$LINDFS_ROOT/regress/regression.out" "$SAVED_OUT" 2>/dev/null || true
    sudo cp "$LINDFS_ROOT/regress/regression.diffs" "$SAVED_DIFFS" 2>/dev/null || true
    sudo chmod 0644 "$SAVED_OUT" "$SAVED_DIFFS" 2>/dev/null || true

    local actual_failures baseline new_failures resolved
    actual_failures="$(awk '($1 == "test" && / FAILED/) {print $2}
                            ($1 == "not" && $2 == "ok") {print $5}' "$REGRESS_LOG" | sort -u)"
    if [[ -f "$BASELINE_FILE" ]]; then
        baseline="$(grep -vE '^\s*(#|$)' "$BASELINE_FILE" | sort -u)"
    else
        echo "baseline $BASELINE_FILE missing; treating all failures as new" >&2
        baseline=""
    fi
    new_failures="$(comm -23 <(echo "$actual_failures") <(echo "$baseline"))"
    resolved="$(comm -13 <(echo "$actual_failures") <(echo "$baseline"))"

    if [[ -n "$resolved" ]]; then
        echo "$PREFIX NOTE: baseline tests now passing (prune regress_known_failures.txt):" >&2
        echo "$resolved" | sed "s/^/$PREFIX         /" >&2
    fi
    # summary line, e.g. "# 205 of 237 tests passed."
    grep -E "of [0-9]+ tests" "$REGRESS_LOG" | tail -2 >&2 || true

    if [[ -n "$new_failures" ]]; then
        # run_test only echoes the last few lines of a failing test's output, so
        # write the full list to the log file where it won't be truncated.
        {
            echo "$PREFIX NEW regress failures (not in baseline):"
            echo "$new_failures" | sed "s/^/$PREFIX     /"
        } >> "$LOG_FILE"
        echo "$(echo "$new_failures" | wc -l | tr -d ' ') new regress failures; full list in $LOG_FILE" >&2
        echo "diffs: $SAVED_DIFFS   results: $SAVED_OUT" >&2
        return 1
    fi
    return 0
}

if [[ "$PG_REGRESS" == "1" ]]; then
    build_filtered_schedule
    echo "$PREFIX running pg_regress serial schedule (this takes a while)..."
    run_test "pg_regress (no new failures vs baseline)" run_regress
else
    echo "$PREFIX SKIP: pg_regress (set PG_REGRESS=1 to enable)" | tee -a "$LOG_FILE"
    log_skip "pg_regress" >/dev/null
fi

# --- final test: clean shutdown ----------------------------------------------
test_clean_shutdown() {
    sudo kill -TERM "$SERVER_PID" 2>/dev/null || return 1
    local i
    for (( i=0; i<SHUTDOWN_TIMEOUT; i++ )); do
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            SERVER_PID=""
            return 0
        fi
        sleep 1
    done
    echo "server did not exit within ${SHUTDOWN_TIMEOUT}s of SIGTERM" >&2
    return 1
}

run_test "clean shutdown (SIGTERM)" test_clean_shutdown

# --- report ------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
{
    echo ""
    echo "$PREFIX $PASS_COUNT/$TOTAL tests passed, $FAIL_COUNT failed, $SKIPPED skipped"
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo "$PREFIX failed tests:"
        for f in "${FAILURES[@]}"; do
            echo "$PREFIX   - $f"
        done
    fi
    echo "$PREFIX Log saved to: $LOG_FILE"
} | tee -a "$LOG_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
