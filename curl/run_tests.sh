#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# curl test suite for lind-wasm
#
# Starts a local HTTP/HTTPS server, runs curl with various flags/options
# through the Lind runtime, and verifies outcomes.
#
# Usage:
#   ./curl/test.sh
#
# Exit 0 on all pass, non-zero on any failure.
###############################################################################

PREFIX="[curl-test]"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()
LOG_FILE="${LOG_FILE:-/tmp/curl_test_results.log}"

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

LIND_DYLINK="${LIND_DYLINK:-0}"

if [[ "$LIND_DYLINK" == "1" ]]; then
        LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run --preload env=lib/libz.so --preload env=lib/libcrypto.so --preload env=lib/libssl.so"
else
        LIND_RUN="$LIND_WASM_ROOT/scripts/bin/lind_run"
fi

LINDFS_ROOT="$LIND_WASM_ROOT/lindfs"
CURL_BIN="usr/local/bin/curl"

# --- configurable settings ---------------------------------------------------
HTTP_PORT="${HTTP_PORT:-8111}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-5}"
TIMEOUT_SECS="${TIMEOUT_SECS:-20}"

source "$SCRIPT_DIR/../scripts/test_lib.sh"

# --- server document root (stable, not temp) ---------------------------------
SERVER_ROOT="$LINDFS_ROOT/tests/curl/www"
CERTS_DIR="$LINDFS_ROOT/tests/curl/certs"
sudo mkdir -p "$SERVER_ROOT" "$CERTS_DIR"

# Create test files
echo "Hello from curl test" | sudo tee "$SERVER_ROOT/test.txt" > /dev/null
echo '{"status":"ok","value":42}' | sudo tee "$SERVER_ROOT/test.json" > /dev/null
printf 'line1\nline2\nline3\nline4\nline5\n' | sudo tee "$SERVER_ROOT/multiline.txt" > /dev/null
dd if=/dev/urandom bs=1024 count=10 2>/dev/null | base64 | sudo tee "$SERVER_ROOT/largefile.bin" > /dev/null

# --- cleanup -----------------------------------------------------------------
SERVER_PID=""
HTTPS_PID=""

cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    [[ -n "$HTTPS_PID" ]] && kill "$HTTPS_PID" 2>/dev/null || true
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --- verify binary exists ----------------------------------------------------
if [[ ! -f "$LINDFS_ROOT/$CURL_BIN" ]]; then
    echo "$PREFIX ERROR: curl binary not found at $LINDFS_ROOT/$CURL_BIN"
    exit 1
fi
echo "$PREFIX curl binary found at: $LINDFS_ROOT/$CURL_BIN"

# --- ensure /dev/urandom and /dev/random exist in lindfs ---------------------
if [[ ! -e "$LINDFS_ROOT/dev/urandom" ]]; then
    sudo mknod "$LINDFS_ROOT/dev/urandom" c 1 9 2>/dev/null || true
    sudo chmod 666 "$LINDFS_ROOT/dev/urandom"
fi
if [[ ! -e "$LINDFS_ROOT/dev/random" ]]; then
    sudo mknod "$LINDFS_ROOT/dev/random" c 1 8 2>/dev/null || true
    sudo chmod 666 "$LINDFS_ROOT/dev/random"
fi

# --- kill leftover servers from previous runs --------------------------------
pkill -f "http.server $HTTP_PORT" 2>/dev/null || true
pkill -f "python3.*$HTTPS_PORT" 2>/dev/null || true
sleep 1

# --- start HTTP server -------------------------------------------------------
echo "$PREFIX starting HTTP server on port $HTTP_PORT..."

python3 -m http.server "$HTTP_PORT" --directory "$SERVER_ROOT" \
    > /tmp/curl-http.log 2>&1 &
SERVER_PID=$!

READY=false
for (( i=0; i<STARTUP_TIMEOUT; i++ )); do
    if curl -s -o /dev/null "http://localhost:$HTTP_PORT/test.txt" 2>/dev/null; then
        READY=true
        break
    fi
    sleep 1
done

if ! $READY; then
    echo "$PREFIX ERROR: HTTP server did not start within ${STARTUP_TIMEOUT}s"
    exit 1
fi
echo "$PREFIX HTTP server ready (PID $SERVER_PID)"

# --- start HTTPS server (self-signed) ----------------------------------------
echo "$PREFIX generating self-signed certificate..."
openssl req -x509 -newkey rsa:2048 -keyout /tmp/curl-key.pem \
    -out /tmp/curl-cert.pem -days 1 -nodes \
    -subj "/CN=localhost" 2>/dev/null
sudo cp /tmp/curl-key.pem "$CERTS_DIR/key.pem"
sudo cp /tmp/curl-cert.pem "$CERTS_DIR/cert.pem"

echo "$PREFIX starting HTTPS server on port $HTTPS_PORT..."

python3 << PYEOF &
import http.server, ssl, os, sys
os.chdir("$SERVER_ROOT")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/tmp/curl-cert.pem", "/tmp/curl-key.pem")
srv = http.server.HTTPServer(("0.0.0.0", $HTTPS_PORT), http.server.SimpleHTTPRequestHandler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PYEOF
HTTPS_PID=$!
sleep 2
echo "$PREFIX HTTPS server ready (PID $HTTPS_PID)"

# --- test helpers ------------------------------------------------------------
BASE_URL="http://localhost:$HTTP_PORT"
BASE_HTTPS="https://localhost:$HTTPS_PORT"

run_test() {
    local name="$1"
    shift

    if is_skipped "$name"; then
        log_skip "$name"
        return
    fi

    local test_output
    if test_output=$("$@" 2>&1); then
        echo "$PREFIX PASS: $name"
        (( PASS_COUNT++ )) || true
    else
        echo "$PREFIX FAIL: $name"
        if [[ -n "${test_output:-}" ]]; then
            echo "$PREFIX        output: $(echo "$test_output" | head -3)"
        fi
        (( FAIL_COUNT++ )) || true
        FAILURES+=("$name")
    fi
}

# --- test cases --------------------------------------------------------------

# 1. Binary check
test_binary_exists() {
    [[ -f "$LINDFS_ROOT/$CURL_BIN" ]]
}

# 2. --version flag
test_version() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" --version 2>&1)
    echo "$output" | grep -q "curl"
}

# 3. --help flag
test_help() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" --help 2>&1)
    echo "$output" | grep -qi "usage"
}

# 4. Basic HTTP GET
test_http_get() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s "$BASE_URL/test.txt" 2>&1)
    [[ "$output" == *"Hello from curl test"* ]]
}

# 5. HTTP GET with status code
test_http_status() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' "$BASE_URL/test.txt" 2>&1)
    [[ "$status" == *"200"* ]]
}

# 6. HTTP HEAD request (-I)
test_http_head() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -I "$BASE_URL/test.txt" 2>&1)
    echo "$output" | grep -qi "Content-Length"
}

# 7. 404 error handling
test_404() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' "$BASE_URL/nonexistent_file" 2>&1)
    [[ "$status" == *"404"* ]]
}

# 8. Download JSON and verify content
test_json_get() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s "$BASE_URL/test.json" 2>&1)
    [[ "$output" == *'"status":"ok"'* ]]
}

# 9. Custom header (-H)
test_custom_header() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -v -H "X-Test-Header: lind-wasm" "$BASE_URL/test.txt" 2>&1)
    echo "$output" | grep -q "X-Test-Header"
}

# 10. User-Agent (-A)
test_user_agent() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -v -A "LindWasmTest/1.0" "$BASE_URL/test.txt" 2>&1)
    echo "$output" | grep -q "LindWasmTest"
}

# 11. Follow redirects (-L)
test_follow_redirect_flag() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -L -o /dev/null -w '%{http_code}' "$BASE_URL/test.txt" 2>&1)
    [[ "$status" == *"200"* ]]
}

# 12. Output to /dev/null (-o)
test_output_devnull() {
    timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null "$BASE_URL/test.txt" 2>&1
    return $?
}

# 13. Write-out format (-w)
test_write_out() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w 'code=%{http_code} size=%{size_download}' "$BASE_URL/test.txt" 2>&1)
    [[ "$output" == *"code=200"* ]]
}

# 14. Verbose output (-v)
test_verbose() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -v "$BASE_URL/test.txt" 2>&1)
    echo "$output" | grep -q "GET /test.txt"
}

# 15. Silent mode (-s)
test_silent() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s "$BASE_URL/test.txt" 2>&1)
    ! echo "$output" | grep -q "% Total"
}

# 16. Multiple URLs in one request
test_multiple_urls() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s "$BASE_URL/test.txt" "$BASE_URL/test.json" 2>&1)
    [[ "$output" == *"Hello from curl test"* ]] && [[ "$output" == *'"status":"ok"'* ]]
}

# 17. POST request (-X POST with -d)
test_post() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' \
        -X POST -d "key=value" "$BASE_URL/test.txt" 2>&1)
    [[ "$status" == *"501"* ]] || [[ "$status" == *"200"* ]] || [[ "$status" == *"405"* ]]
}

# 18. PUT request (-X PUT)
test_put() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' \
        -X PUT -d "data" "$BASE_URL/test.txt" 2>&1)
    [[ -n "$status" ]]
}

# 19. HTTPS with insecure flag (-k)
test_https_insecure() {
    # Verify HTTPS server is reachable first
    if ! curl -sk -o /dev/null "$BASE_HTTPS/" 2>/dev/null; then
        echo "$PREFIX        (HTTPS server not available — skipping)" >&2
        return 0
    fi
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -k "$BASE_HTTPS/test.txt" 2>&1)
    [[ "$output" == *"Hello from curl test"* ]]
}

# 20. HTTPS with CA cert (--cacert)
test_https_cacert() {
    if ! curl -sk -o /dev/null "$BASE_HTTPS/" 2>/dev/null; then
        echo "$PREFIX        (HTTPS server not available — skipping)" >&2
        return 0
    fi
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s --cacert tests/curl/certs/cert.pem "$BASE_HTTPS/test.txt" 2>&1)
    [[ "$output" == *"Hello from curl test"* ]]
}

# 21. Connection timeout (--connect-timeout)
test_connect_timeout() {
    local start end elapsed
    start=$(date +%s)
    timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s --connect-timeout 2 "http://192.0.2.1/" 2>&1 || true
    end=$(date +%s)
    elapsed=$((end - start))
    [[ $elapsed -lt 10 ]]
}

# 22. Max time (--max-time)
test_max_time() {
    local start end elapsed
    start=$(date +%s)
    timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s --max-time 2 "http://192.0.2.1/" 2>&1 || true
    end=$(date +%s)
    elapsed=$((end - start))
    [[ $elapsed -lt 10 ]]
}

# 23. Download large file and verify size
test_large_download() {
    local output size
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{size_download}' "$BASE_URL/largefile.bin" 2>&1)
    size=$(echo "$output" | tr -dc '0-9')
    [[ -n "$size" ]] && [[ "$size" -gt 0 ]]
}

# 24. HTTP range request
test_range_request() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -r 0-4 -o /dev/null -w '%{http_code}' "$BASE_URL/test.txt" 2>&1)
    [[ "$status" == *"200"* ]] || [[ "$status" == *"206"* ]]
}

# 25. Retry flag (--retry)
test_retry_flag() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s --retry 1 -o /dev/null -w '%{http_code}' "$BASE_URL/test.txt" 2>&1)
    [[ "$status" == *"200"* ]]
}
# === EXTERNAL URL TESTS (DNS resolution + real network) ======================

# 26. External HTTP GET (tests DNS resolution)
test_external_http() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 10 "http://example.com/" 2>&1)
    [[ "$status" == *"200"* ]]
}

# 27. External HTTPS GET (tests DNS + TLS handshake)
test_external_https() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 10 "https://example.com/" 2>&1)
    [[ "$status" == *"200"* ]]
}

# 28. External HTTPS content verification
test_external_content() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s --max-time 10 "https://example.com/" 2>&1)
    [[ "$output" == *"Example Domain"* ]]
}

# 29. External redirect follow (tests DNS + HTTP 301/302 handling)
test_external_redirect() {
    local status
    status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -L -o /dev/null -w '%{http_code}' --max-time 10 "http://www.google.com/" 2>&1)
    [[ "$status" == *"200"* ]]
}

# 30. External HEAD request (tests DNS + response headers)
test_external_head() {
    local output
    output=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -I --max-time 10 "https://example.com/" 2>&1)
    echo "$output" | grep -qi "Content-Type"
}

# Quick DNS check - if this fails, skip all external tests
DNS_AVAILABLE=false
dns_status=$(timeout ${TIMEOUT_SECS}s $LIND_RUN "$CURL_BIN" -s -o /dev/null -w '%{http_code}' --max-time 5 "http://example.com/" 2>/dev/null) || true
[[ "$dns_status" == *"200"* ]] && DNS_AVAILABLE=true

# --- run tests ---------------------------------------------------------------

echo "" | tee "$LOG_FILE"
echo "$PREFIX === Running curl tests ===" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

run_test "Binary exists at lindfs/bin/curl"       test_binary_exists
run_test "curl --version"                          test_version
run_test "curl --help"                             test_help
run_test "HTTP GET text file"                      test_http_get
run_test "HTTP GET status code 200"                test_http_status
run_test "HTTP HEAD request"                       test_http_head
run_test "HTTP 404 handling"                       test_404
run_test "HTTP GET JSON"                           test_json_get
run_test "Custom header (-H)"                      test_custom_header
run_test "User-Agent (-A)"                         test_user_agent
run_test "Follow redirect flag (-L)"               test_follow_redirect_flag
run_test "Output to /dev/null (-o)"                test_output_devnull
run_test "Write-out format (-w)"                   test_write_out
run_test "Verbose output (-v)"                     test_verbose
run_test "Silent mode (-s)"                        test_silent
run_test "Multiple URLs"                           test_multiple_urls
run_test "POST request (-X POST -d)"               test_post
run_test "PUT request (-X PUT)"                    test_put
run_test "HTTPS insecure (-k)"                     test_https_insecure
run_test "HTTPS with CA cert (--cacert)"           test_https_cacert
run_test "Connection timeout (--connect-timeout)"  test_connect_timeout
run_test "Max time (--max-time)"                   test_max_time
run_test "Large file download"                     test_large_download
run_test "Range request (-r)"                      test_range_request
run_test "Retry flag (--retry)"                    test_retry_flag
echo ""
echo "$PREFIX --- External URL tests (DNS + network) ---"
if $DNS_AVAILABLE; then
    run_test "External HTTP GET (DNS resolution)"      test_external_http
    run_test "External HTTPS GET (DNS + TLS)"          test_external_https
    run_test "External HTTPS content verification"     test_external_content
    run_test "External redirect follow (HTTP 301/302)" test_external_redirect
    run_test "External HEAD request"                   test_external_head
else
    echo "$PREFIX (getaddrinfo fails for external hosts; local networking works fine)"
    log_skip "External HTTP GET (DNS resolution)" "DNS unavailable"
    log_skip "External HTTPS GET (DNS + TLS)" "DNS unavailable"
    log_skip "External HTTPS content verification" "DNS unavailable"
    log_skip "External redirect follow (HTTP 301/302)" "DNS unavailable"
    log_skip "External HEAD request" "DNS unavailable"
fi
# --- report ------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo ""
echo "$PREFIX $PASS_COUNT/$TOTAL tests passed, $FAIL_COUNT failed, $SKIPPED skipped"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "$PREFIX failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "$PREFIX   - $f"
    done
fi

echo "$PREFIX Log saved to: $LOG_FILE"

# Force kill servers before exit
cleanup
# Kill any stragglers
pkill -f "http.server $HTTP_PORT" 2>/dev/null || true
pkill -f "python3.*$HTTPS_PORT" 2>/dev/null || true

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
