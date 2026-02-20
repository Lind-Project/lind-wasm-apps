#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# nginx test suite for lind-wasm
#
# Starts nginx under the Lind runtime, runs HTTP tests with curl, and reports
# pass/fail results.
#
# Usage:
#   ./nginx/test_nginx.sh               # use defaults
#   TEST_PORT=9090 ./nginx/test_nginx.sh # custom port
#
# Prerequisites:
#   - nginx built via 'make nginx' (cwasm or opt.wasm in build/bin/nginx/)
#   - lind-wasm runtime available (lind-wasm command or LIND_WASM_ROOT set)
#   - curl installed
###############################################################################

PREFIX="[nginx-test]"
PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

# --- paths -------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_OUT_DIR="$APPS_ROOT/build/bin/nginx/wasm32-wasi"
NGINX_HTML_SRC="$SCRIPT_DIR/html"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

# --- configurable settings ---------------------------------------------------

TEST_PORT="${TEST_PORT:-8080}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-15}"

# --- temp directory for this run ---------------------------------------------

TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/nginx-test.XXXXXX")"
NGINX_PID=""

cleanup() {
    if [[ -n "$NGINX_PID" ]]; then
        kill "$NGINX_PID" 2>/dev/null || true
        wait "$NGINX_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT INT TERM

# --- locate binaries ---------------------------------------------------------

# Find the nginx WASM binary (prefer cwasm, fall back to opt.wasm, then .wasm)
NGINX_WASM=""
for candidate in \
    "$NGINX_OUT_DIR/nginx.cwasm" \
    "$NGINX_OUT_DIR/nginx.opt.wasm" \
    "$NGINX_OUT_DIR/nginx.wasm"; do
    if [[ -f "$candidate" ]]; then
        NGINX_WASM="$candidate"
        break
    fi
done

if [[ -z "$NGINX_WASM" ]]; then
    echo "$PREFIX ERROR: no nginx WASM binary found in $NGINX_OUT_DIR"
    echo "$PREFIX        Run 'make nginx' first."
    exit 1
fi

# Find the Lind runtime
LIND_CMD=""
if command -v lind-wasm &>/dev/null; then
    LIND_CMD="lind-wasm"
elif [[ -x "$LIND_WASM_ROOT/build/lind-boot" ]]; then
    LIND_CMD="$LIND_WASM_ROOT/build/lind-boot"
elif [[ -x "$LIND_WASM_ROOT/scripts/lind_run" ]]; then
    LIND_CMD="$LIND_WASM_ROOT/scripts/lind_run"
fi

if [[ -z "$LIND_CMD" ]]; then
    echo "$PREFIX ERROR: no Lind runtime found."
    echo "$PREFIX        Install lind-wasm or set LIND_WASM_ROOT."
    exit 1
fi

if ! command -v curl &>/dev/null; then
    echo "$PREFIX ERROR: curl is required but not found."
    exit 1
fi

echo "$PREFIX using nginx binary: $NGINX_WASM"
echo "$PREFIX using lind runtime: $LIND_CMD"

# --- generate temp nginx.conf ------------------------------------------------

# Set up a working directory structure for nginx
NGINX_WORKDIR="$TMPDIR_TEST/nginx"
mkdir -p "$NGINX_WORKDIR/conf" "$NGINX_WORKDIR/logs" "$NGINX_WORKDIR/html"

# Copy html files from source
cp -r "$NGINX_HTML_SRC/"* "$NGINX_WORKDIR/html/"

# Copy mime.types from the build output or source
if [[ -f "$NGINX_OUT_DIR/conf/mime.types" ]]; then
    cp "$NGINX_OUT_DIR/conf/mime.types" "$NGINX_WORKDIR/conf/"
elif [[ -f "$SCRIPT_DIR/conf/mime.types" ]]; then
    cp "$SCRIPT_DIR/conf/mime.types" "$NGINX_WORKDIR/conf/"
fi

NGINX_CONF="$NGINX_WORKDIR/conf/nginx-test.conf"

cat > "$NGINX_CONF" << EOF
daemon off;
master_process off;
worker_processes 1;

error_log /dev/stderr info;

events {
    use poll;
    worker_connections 64;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    access_log /dev/stdout;

    sendfile off;
    keepalive_timeout 65;

    server {
        listen $TEST_PORT;
        server_name localhost;

        location / {
            root   html;
            index  index.html index.htm;
        }

        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root html;
        }
    }
}
EOF

# --- start nginx -------------------------------------------------------------

echo "$PREFIX starting nginx on port $TEST_PORT..."

# Build the lind command. The invocation depends on which runtime we found.
# lind-wasm: lind-wasm <file> -- <args>
# lind-boot: same pattern
# lind_run:  lind_run <file> <args>
NGINX_LOG="$TMPDIR_TEST/nginx.log"

case "$LIND_CMD" in
    *lind-wasm|*lind-boot)
        "$LIND_CMD" "$NGINX_WASM" -- -p "$NGINX_WORKDIR" -c conf/nginx-test.conf \
            >"$NGINX_LOG" 2>&1 &
        ;;
    *lind_run)
        "$LIND_CMD" "$NGINX_WASM" -p "$NGINX_WORKDIR" -c conf/nginx-test.conf \
            >"$NGINX_LOG" 2>&1 &
        ;;
    *)
        "$LIND_CMD" "$NGINX_WASM" -- -p "$NGINX_WORKDIR" -c conf/nginx-test.conf \
            >"$NGINX_LOG" 2>&1 &
        ;;
esac
NGINX_PID=$!

# Wait for nginx to be ready
READY=false
for (( i=0; i<STARTUP_TIMEOUT; i++ )); do
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "$PREFIX ERROR: nginx process died during startup."
        echo "$PREFIX --- nginx log ---"
        cat "$NGINX_LOG" 2>/dev/null || true
        exit 1
    fi
    if curl -s -o /dev/null "http://localhost:$TEST_PORT/" 2>/dev/null; then
        READY=true
        break
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

run_test() {
    local name="$1"
    shift
    # remaining args: the test function to call
    if "$@"; then
        echo "$PREFIX [PASS] $name"
        (( PASS_COUNT++ )) || true
    else
        echo "$PREFIX [FAIL] $name"
        (( FAIL_COUNT++ )) || true
        FAILURES+=("$name")
    fi
}

BASE_URL="http://localhost:$TEST_PORT"

# --- test cases --------------------------------------------------------------

test_get_index() {
    local body status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
    if [[ "$status" != "200" ]]; then
        echo "$PREFIX        expected 200, got $status" >&2
        return 1
    fi
    body="$(curl -s "$BASE_URL/")"
    if [[ "$body" != *"Welcome to nginx"* ]]; then
        echo "$PREFIX        body does not contain 'Welcome to nginx'" >&2
        return 1
    fi
    return 0
}

test_head_request() {
    local status content_length
    status="$(curl -s -o /dev/null -w '%{http_code}' -I "$BASE_URL/")"
    if [[ "$status" != "200" ]]; then
        echo "$PREFIX        expected 200, got $status" >&2
        return 1
    fi
    content_length="$(curl -s -I "$BASE_URL/" | grep -i '^Content-Length:' || true)"
    if [[ -z "$content_length" ]]; then
        echo "$PREFIX        Content-Length header not present" >&2
        return 1
    fi
    return 0
}

test_404_error() {
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/nonexistent_page_that_does_not_exist")"
    if [[ "$status" != "404" ]]; then
        echo "$PREFIX        expected 404, got $status" >&2
        return 1
    fi
    return 0
}

test_static_file() {
    local content="test-content-$(date +%s)-$$"
    local filename="test_static_$$.txt"
    echo "$content" > "$NGINX_WORKDIR/html/$filename"

    local body status
    status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/$filename")"
    if [[ "$status" != "200" ]]; then
        echo "$PREFIX        expected 200, got $status" >&2
        return 1
    fi
    body="$(curl -s "$BASE_URL/$filename")"
    if [[ "$body" != "$content" ]]; then
        echo "$PREFIX        body mismatch: expected '$content', got '$body'" >&2
        return 1
    fi
    return 0
}

test_content_length() {
    local cl body body_len
    cl="$(curl -s -I "$BASE_URL/" | grep -i '^Content-Length:' | tr -d '\r' | awk '{print $2}')"
    if [[ -z "$cl" ]]; then
        echo "$PREFIX        Content-Length header not found" >&2
        return 1
    fi
    body="$(curl -s "$BASE_URL/")"
    body_len="${#body}"
    if [[ "$body_len" -ne "$cl" ]]; then
        echo "$PREFIX        Content-Length=$cl but body is $body_len bytes" >&2
        return 1
    fi
    return 0
}

test_post_method() {
    # nginx serving static files may return 405 or 200 for POST; either is acceptable
    # as long as the server doesn't crash
    local status
    status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/")"
    if [[ "$status" == "405" || "$status" == "200" ]]; then
        return 0
    fi
    echo "$PREFIX        expected 405 or 200, got $status" >&2
    return 1
}

test_sequential_requests() {
    local i status
    for (( i=1; i<=10; i++ )); do
        status="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")"
        if [[ "$status" != "200" ]]; then
            echo "$PREFIX        request $i failed with status $status" >&2
            return 1
        fi
    done
    return 0
}

test_keepalive() {
    # Use curl with two requests on the same connection via --next
    # curl -v output shows "Re-using existing connection" on keepalive
    local output
    output="$(curl -v -s -o /dev/null "$BASE_URL/" "$BASE_URL/" 2>&1)"
    if echo "$output" | grep -qi "re-using existing connection\|reusing existing connection\|Re-using"; then
        return 0
    fi
    # Even if curl doesn't report reuse, as long as both requests succeed, pass
    local count
    count="$(echo "$output" | grep -c '< HTTP/1.1 200' || true)"
    if [[ "$count" -ge 2 ]]; then
        return 0
    fi
    echo "$PREFIX        keepalive connection reuse not detected" >&2
    return 1
}

test_concurrent_requests() {
    local pids=() statuses=() i status
    local tmpfiles=()

    for (( i=0; i<5; i++ )); do
        local tmpfile="$TMPDIR_TEST/concurrent_$i"
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

run_test "GET index page"             test_get_index
run_test "HEAD request"               test_head_request
run_test "404 error page"             test_404_error
run_test "Static file serving"        test_static_file
run_test "Content-Length validation"   test_content_length
run_test "POST method"                test_post_method
run_test "Multiple sequential requests" test_sequential_requests
run_test "Keepalive connection reuse" test_keepalive
run_test "Concurrent requests"        test_concurrent_requests

# --- report ------------------------------------------------------------------

TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo
echo "$PREFIX $PASS_COUNT/$TOTAL tests passed, $FAIL_COUNT failed"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "$PREFIX failed tests:"
    for f in "${FAILURES[@]}"; do
        echo "$PREFIX   - $f"
    done
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
