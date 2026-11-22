# nginx with the same paths and core module choices as compile_nginx.sh
WASM_RUN_ARGS="--enable-fpcast"  # lind_run flags in --mode wasm, as in nginx/run_tests.sh
recipe_build() {
  # lindfs has no rewritten libcrypt.so: link lind glibc's libcrypt.a statically.
  mkdir -p "$SRC/staticlibs"; cp "${LIND_GLIBC:-$LIND_WASM_ROOT/glibc-2.35}/build/crypt/libcrypt.a" "$SRC/staticlibs/"
  ./configure --with-ld-opt="-L$SRC/staticlibs" --with-cc="$MPK_CC" --with-cc-opt="$CFLAGS" \
    --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx --conf-path=/etc/nginx/nginx.conf \
    --modules-path=/usr/lib/nginx/modules --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log --pid-path=/var/run/nginx/nginx.pid \
    --lock-path=/var/run/nginx/nginx.lock --with-poll_module --without-select_module \
    --without-http_rewrite_module --without-http_gzip_module --without-pcre
  make -j"$JOBS"
  stage_bin objs/nginx /usr/sbin/nginx
}
recipe_smoke() {
  mkdir -p "$LINDFS/var/log/nginx" "$LINDFS/var/run/nginx" "$LINDFS/tmp/mpk-nginx/html"
  printf 'nginx-mpk-ok\n' > "$LINDFS/tmp/mpk-nginx/html/index.html"
  fixture /tmp/mpk-nginx/nginx.conf <<'CONF'
daemon off;
master_process off;
error_log /tmp/mpk-nginx/error.log;
pid /tmp/mpk-nginx/nginx.pid;
events { worker_connections 16; }
http {
  access_log off;
  client_body_temp_path /tmp/mpk-nginx;
  server { listen 127.0.0.1:18080; root /tmp/mpk-nginx/html; }
}
CONF
  smoke version "nginx version" -- /usr/sbin/nginx -v
  smoke config-test "successful" -- /usr/sbin/nginx -t -c /tmp/mpk-nginx/nginx.conf
  # Serve one request: nginx under lind-boot, client is the host's curl. The
  # server log stays outside lindfs: nginx (as root) chowns its temp path.
  local log; log="$(mktemp)"
  if curl -s --max-time 2 -o /dev/null http://127.0.0.1:18080/ 2>/dev/null; then
    echo "SMOKE FAIL: http-get — port 18080 already in use before the server started"
    rm -f "$log"; return 0
  fi
  ( cd "$LIND_WASM_ROOT" && exec timeout --kill-after=5 20 "$LIND_RUN" "${LIND_RUN_FLAGS[@]}" /usr/sbin/nginx \
      -c /tmp/mpk-nginx/nginx.conf ) >"$log" 2>&1 &
  local server=$! out="" i
  for i in $(seq 1 30); do
    out="$(curl -s --max-time 2 http://127.0.0.1:18080/ 2>/dev/null)" && [[ -n "$out" ]] && break
    sleep 0.5
  done
  echo "--- smoke http-get: host curl -> nginx under lind-boot"; echo "$out"
  if [[ "$out" == *nginx-mpk-ok* ]]; then echo "SMOKE PASS: http-get"
  else echo "SMOKE FAIL: http-get — no response: $(grep -v '^\[lind' "$log" | tail -n 3 | tr '\n' ' ' | head -c 200)"; fi
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  # lind_run re-execs through sudo, so the root-owned lind-boot can outlive
  # the SIGKILL that timeout sends to sudo; it would keep port 18080.
  local stray; stray="$(pgrep -f -- '/usr/sbin/nginx -c /tmp/mpk-nginx/nginx.conf' || true)"
  [[ -z "$stray" ]] || sudo -n kill -KILL $stray 2>/dev/null || true
  cat "$log"; rm -f "$log"
}
