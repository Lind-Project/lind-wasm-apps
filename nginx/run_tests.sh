#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# nginx test suite for lind-wasm
#
# Usage:
#   ./nginx/test.sh                     # use defaults
#   TEST_PORT=9090 ./nginx/test.sh      # custom port
###############################################################################

PREFIX="[nginx-test]"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
LOG_FILE="${LOG_FILE:-/tmp/nginx_test_results.log}"

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi
LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run --enable-fpcast"
LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
NGINX_BIN="usr/sbin/nginx"
NGINX_CONF_DIR="$LINDFS_ROOT/etc/nginx"
NGINX_HTML_DIR="$LINDFS_ROOT/var/www/html"

# --- configurable settings ---------------------------------------------------
TEST_PORT="${TEST_PORT:-8080}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-15}"
NGINX_PID=""
NGINX_LOG="/tmp/nginx-test.$$.log"
TEST_CONF="/etc/nginx/nginx-test.conf"
HOST_TEST_CONF="$NGINX_CONF_DIR/nginx-test.conf"

# --- cleanup -----------------------------------------------------------------
cleanup() {
    if [[ -n "$NGINX_PID" ]]; then
        sudo kill "$NGINX_PID" 2>/dev/null || true
        wait "$NGINX_PID" 2>/dev/null || true
    fi
    sudo rm -f "$HOST_TEST_CONF" 2>/dev/null || true
    sudo rm -f "$NGINX_HTML_DIR/test_static_"*.txt 2>/dev/null || true
    sudo rm -f "$LINDFS_ROOT/var/log/nginx/access.log" 2>/dev/null || true
    sudo rm -f "$LINDFS_ROOT/var/log/nginx/error.log" 2>/dev/null || true
    rm -f "$NGINX_LOG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- verify prerequisites ----------------------------------------------------
if [[ ! -f "$LINDFS_ROOT/$NGINX_BIN" ]]; then
    echo "$PREFIX ERROR: nginx binary not found at $LINDFS_ROOT/$NGINX_BIN"
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "$PREFIX ERROR: curl is required but not found."
    exit 1
fi
echo "$PREFIX nginx binary found at: $LINDFS_ROOT/$NGINX_BIN"

# --- generate test nginx.conf ------------------------------------------------
sudo mkdir -p "$LINDFS_ROOT/var/log/nginx"
cat > "$HOST_TEST_CONF" << EOF
daemon off;
master_process off;
worker_processes 1;
error_log /var/log/nginx/error.log info;
events {
    use poll;
    worker_connections 64;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    access_log /var/log/nginx/access.log;
    sendfile off;
    keepalive_timeout 65;
    server {
        listen $TEST_PORT;
        server_name localhost;
        location / {
            root   /var/www/html;
            index  index.html index.htm;
        }
        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root /var/www/html;
        }
    }
}
EOF

# --- start nginx -------------------------------------------------------------
echo "$PREFIX starting nginx on port $TEST_PORT..."
setsid $LIND_RUN "$NGINX_BIN" -p / -c "$TEST_CONF" \
    >"$NGINX_LOG" 2>&1 &
NGINX_PID=$!

# FIX 1: Readiness check now also verifies the Server header identifies nginx,
# so we don't accidentally proceed against some other process on the port.
READY=false
for (( i=0; i<STARTUP_TIMEOUT; i++ )); do
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "$PREFIX ERROR: nginx process died during startup."
        echo "$PREFIX --- nginx log ---"
        cat "$NGINX_LOG" 2>/dev/null || true
        exit 1
    fi
    if curl -s -o /dev/null "http://localhost:$TEST_PORT/" 2>/dev/null; then
        server_header="$(curl -sI "http://localhost:$TEST_PORT/" 2>/dev/null \
            | grep -i '^Server:' | tr -d '\r' || true)"
        if echo "$server_header" | grep -qi "nginx"; then
            READY=true
            break
        fi
    fi
    sleep 1
done
if ! $READY; then
    echo "$PREFIX ERROR: nginx did not become ready within ${STARTUP_TIMEOUT}s."
    echo "$PREFIX --- nginx log ---"
    cat "$NGINX_LOG" 2>/dev/null || true
    kill "$NGINX_PID" 2>/dev/null || true
    exit 1
fi
echo "$PREFIX nginx ready (PID $NGINX_PID)"

# --- test helpers ------------------------------------------------------------
# FIX 4: All output from run_test (PASS/FAIL lines + any failure details) is
# now piped through tee so the log file captures the full test results, not
# just the header/footer summary.
run_test() {
    local name="$1"
    shift
    local test_output
    if test_output=$("$@" 2>&1); then
        echo "$PREFIX [PASS] $name" | tee -a "$LOG_FILE"
        (( PASS_COUNT++ )) || true
    else
        echo "$PREFIX [FAIL] $name" | tee -a "$LOG_FILE"
        if [[ -n "${test_output:-}" ]]; then
            echo "$PREFIX        output: $(echo "$test_output" | head -3)" | tee -a "$LOG_FILE"
        fi
        (( FAIL_COUNT++ )) || true
        FAILURES+=("$name")
    fi
}
BASE_URL="http://localhost:$TEST_PORT"

# --- test cases --------------------------------------------------------------
test_get_index() {
    local body status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
    [[ "$status" == "200" ]] || { echo "$PREFIX        expected 200, got $status" >&2; return 1; }
    body="$(curl -s "$BASE_URL/")"
    [[ "$body" == *"Welcome to nginx"* ]] || { echo "$PREFIX        body does not contain 'Welcome to nginx'" >&2; return 1; }
}

test_head_request() {
    local status content_length
    status="$(curl -s -o /dev/null -w '%{http_code}' -I "$BASE_URL/")"
    [[ "$status" == "200" ]] || { echo "$PREFIX        expected 200, got $status" >&2; return 1; }
    content_length="$(curl -s -I "$BASE_URL/" | grep -i '^Content-Length:' || true)"
    [[ -n "$content_length" ]] || { echo "$PREFIX        Content-Length header not present" >&2; return 1; }
}

test_404_error() {
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/nonexistent_page_that_does_not_exist")"
    [[ "$status" == "404" ]] || { echo "$PREFIX        expected 404, got $status" >&2; return 1; }
}

test_static_file() {
    local content="test-content-$(date +%s)-$$"
    local filename="test_static_$$.txt"
    echo "$content" > "$NGINX_HTML_DIR/$filename"
    local body status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$filename")"
    [[ "$status" == "200" ]] || { echo "$PREFIX        expected 200, got $status" >&2; return 1; }
    body="$(curl -s "$BASE_URL/$filename")"
    [[ "$body" == "$content" ]] || { echo "$PREFIX        body mismatch" >&2; return 1; }
}

test_content_length() {
    local cl body_len
    cl="$(curl -s -I "$BASE_URL/" | grep -i '^Content-Length:' | tr -d '\r' | awk '{print $2}')"
    [[ -n "$cl" ]] || { echo "$PREFIX        Content-Length header not found" >&2; return 1; }
    body_len="$(curl -s -o /dev/null -w '%{size_download}' "$BASE_URL/")"
    [[ "$body_len" -eq "$cl" ]] || { echo "$PREFIX        Content-Length=$cl but body is $body_len bytes" >&2; return 1; }
}

# FIX 2: POST to a static-file-only nginx should consistently return 405.
# Accepting 200 as well made the contract ambiguous -- we now enforce 405.
test_post_method() {
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/")"
    [[ "$status" == "405" ]] || { echo "$PREFIX        expected 405, got $status" >&2; return 1; }
}

test_sequential_requests() {
    local i status
    for (( i=1; i<=10; i++ )); do
        status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
        [[ "$status" == "200" ]] || { echo "$PREFIX        request $i failed with status $status" >&2; return 1; }
    done
}

# FIX 3: Two 200s don't prove connection reuse -- curl could have opened two
# separate connections and both succeeded.  We now parse curl's verbose output
# for the explicit "Re-using existing connection" / "reuse" message, which only
# appears when the TCP connection was actually kept alive and reused.
test_keepalive() {
    local output
    output="$(curl -v -s -o /dev/null "$BASE_URL/" "$BASE_URL/" 2>&1)"
    if echo "$output" | grep -qiE \
        "re-using existing connection|reusing existing connection|Re-using|reuse conn"; then
        return 0
    fi
    echo "$PREFIX        keepalive connection reuse message not found in curl output" >&2
    return 1
}

test_concurrent_requests() {
    local pids=() i status tmpfiles=()
    for (( i=0; i<5; i++ )); do
        local tmpfile="/tmp/nginx-test-concurrent_$i"
        tmpfiles+=("$tmpfile")
        curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/" > "$tmpfile" 2>/dev/null &
        pids+=($!)
    done
    local all_ok=true
    for (( i=0; i<5; i++ )); do
        wait "${pids[$i]}" || true
        status="$(cat "${tmpfiles[$i]}" 2>/dev/null || echo "000")"
        if [[ "$status" != "200" ]]; then
            echo "$PREFIX        concurrent request $((i+1)) returned $status" >&2
            all_ok=false
        fi
    done
    $all_ok
}

# --- run tests ---------------------------------------------------------------
# FIX 4 (cont.): Initialize the log file here and tee the section header into
# it so the file always starts clean and captures everything from this run.
: > "$LOG_FILE"
{ echo ""; echo "$PREFIX === Running nginx tests ==="; echo ""; } | tee -a "$LOG_FILE"

run_test "GET index page"               test_get_index
run_test "HEAD request"                  test_head_request
run_test "404 error page"               test_404_error
run_test "Static file serving"           test_static_file
run_test "Content-Length validation"      test_content_length
run_test "POST method"                   test_post_method
run_test "Multiple sequential requests"  test_sequential_requests
run_test "Keepalive connection reuse"    test_keepalive
run_test "Concurrent requests"           test_concurrent_requests

# --- report ------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
{
    echo ""
    echo "$PREFIX $PASS_COUNT/$TOTAL tests passed, $FAIL_COUNT failed"
    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        echo "$PREFIX failed tests:"
        for f in "${FAILURES[@]}"; do
            echo "$PREFIX   - $f"
        done
    fi
    echo "$PREFIX Log saved to: $LOG_FILE"
} | tee -a "$LOG_FILE"

cleanup
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
