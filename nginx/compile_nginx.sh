#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Nginx WASM build helper for lind-wasm-apps (vendored nginx/)
#
# Goal: build nginx as wasm32-wasi using lind-wasm sysroot.
#
# IMPORTANT CONTEXT (based on your logs):
# - The lind-wasm glibc sysroot produces WASM binaries that are NOT reliably
#   runnable under plain `wasmtime run` during nginx's configure-time probes.
#   (you saw wasm-ld signature mismatch + wasmtime panic)
# - So we DISABLE *runtime* autotest execution in nginx's auto scripts and
#   provide cross-compile defaults for key probes (sizeof(int), etc.).
#
# This gets configure past the "C compiler ... found but is not working" gate
# without trying to execute test binaries.
#
# Also:
# - nginx configure expects CC/--with-cc to be an *executable path* (no spaces),
#   so we use a wrapper script for clang with --target/--sysroot.
###############################################################################

# ----------------------------------------------------------------------
# 0) Paths and repo layout (match lmbench/bash style)
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
fi

APPS_BUILD="${APPS_BUILD:-$REPO_ROOT/build}"
MERGED_SYSROOT="${MERGED_SYSROOT:-$APPS_BUILD/sysroot_merged}"
TOOL_ENV="${TOOL_ENV:-$APPS_BUILD/.toolchain.env}"
JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

OUT_DIR="$APPS_BUILD/bin/nginx/wasm32-wasi"
WORK_SRC="$APPS_BUILD/nginx-src"
mkdir -p "$OUT_DIR"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[nginx] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[nginx] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

# Optional post-processing tool (best-effort)
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"

# ----------------------------------------------------------------------
# 2) Copy vendored nginx source into build/ (keep repo clean)
# ----------------------------------------------------------------------
echo "[nginx] preparing source copy -> $WORK_SRC"
rm -rf "$WORK_SRC"
mkdir -p "$WORK_SRC"
rsync -a --delete "$REPO_ROOT/nginx/" "$WORK_SRC/"

cd "$WORK_SRC"

# ----------------------------------------------------------------------
# 3) Cross mode: disable *runtime* configure probes
# ----------------------------------------------------------------------
export NGX_WASM_CROSS=1

echo "[nginx] patching nginx auto scripts to disable run-probes (NGX_WASM_CROSS=1)"

# ---- Patch auto/feature ----
# Force ngx_feature_run=no so it never tries to execute objs/autotest.
# This still allows compile/link checks to drive "found"/"not found".
if [[ -f auto/feature ]]; then
  if ! grep -q 'NGX_WASM_CROSS' auto/feature; then
    # Insert right after "ngx_found=no"
    awk '
      {print}
      $0 ~ /^ngx_found=no$/ {
        print ""
        print "# --- lind-wasm cross: disable runtime autotests ---"
        print "if test -n \"${NGX_WASM_CROSS:-}\"; then"
        print "    ngx_feature_run=no"
        print "fi"
        print "# -------------------------------------------------"
      }
    ' auto/feature > auto/feature.new
    mv auto/feature.new auto/feature
  fi
fi

# Sanity check
if [[ -f auto/feature ]] && ! grep -q 'ngx_feature_run=no' auto/feature; then
  echo "[nginx] ERROR: failed to patch auto/feature to disable runtime tests" >&2
  exit 1
fi

# ---- Patch auto/types/sizeof ----
# Provide cross defaults for common C types on wasm32, and skip execution.
if [[ -f auto/types/sizeof ]]; then
  if ! grep -q 'NGX_WASM_CROSS' auto/types/sizeof; then
    # 1) After "ngx_size=" inject a cross-size assignment block
    awk '
      {print}
      $0 ~ /^ngx_size=$/ {
        print ""
        print "# --- lind-wasm cross: provide sizeof() without running autotest ---"
        print "if [ -n \"${NGX_WASM_CROSS:-}\" ]; then"
        print "    case \"$ngx_type\" in"
        print "        \"char\"|\"signed char\"|\"unsigned char\"|\"u_char\") ngx_size=1 ;;"
        print "        \"short\"|\"unsigned short\") ngx_size=2 ;;"
        print "        \"int\"|\"unsigned int\"|\"int32_t\"|\"uint32_t\") ngx_size=4 ;;"
        print "        \"long\"|\"unsigned long\") ngx_size=4 ;;"
        print "        \"long long\"|\"unsigned long long\"|\"int64_t\"|\"uint64_t\") ngx_size=8 ;;"
        print "        \"void *\"|\"char *\"|\"u_char *\"|\"size_t\"|\"ssize_t\"|\"ptrdiff_t\") ngx_size=4 ;;"
        print "        \"off_t\"|\"time_t\") ngx_size=8 ;;"
        print "        \"double\") ngx_size=8 ;;"
        print "        *) ngx_size=4 ;;"
        print "    esac"
        print "fi"
        print "# ------------------------------------------------------------------"
      }
    ' auto/types/sizeof > auto/types/sizeof.new
    mv auto/types/sizeof.new auto/types/sizeof

    # 2) Prevent overwriting ngx_size by running $NGX_AUTOTEST
    #    Change: if [ -x $NGX_AUTOTEST ]; then
    #    To:     if [ -z "${NGX_WASM_CROSS:-}" ] && [ -x $NGX_AUTOTEST ]; then
    sed -i 's/if \[ -x \$NGX_AUTOTEST \ ]; then/if [ -z "${NGX_WASM_CROSS:-}" ] \&\& [ -x $NGX_AUTOTEST ]; then/' auto/types/sizeof
  fi
fi

# Sanity check
if [[ -f auto/types/sizeof ]] && ! grep -q 'provide sizeof() without running autotest' auto/types/sizeof; then
  echo "[nginx] ERROR: failed to patch auto/types/sizeof for cross sizeof defaults" >&2
  exit 1
fi

echo "[nginx] patch OK (run-probes disabled; sizeof defaults installed)"

# ----------------------------------------------------------------------
# 4) Configure + build
#
# IMPORTANT:
#   nginx configure expects CC/--with-cc to be an executable path (no spaces).
#   Use a wrapper script that injects --target/--sysroot for every compile.
# ----------------------------------------------------------------------
TARGET="wasm32-unknown-wasi"

CC_WRAPPER="$APPS_BUILD/nginx-wasi-cc.sh"
cat > "$CC_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$CLANG" --target=$TARGET --sysroot="$MERGED_SYSROOT" "\$@"
EOF
chmod +x "$CC_WRAPPER"
echo "[nginx] CC_WRAPPER = $CC_WRAPPER"

CC_OPT=(
  "-O2"
  "-g0"
  "-fno-common"
)

echo "[nginx] configure (baseline, minimal modules)"
CC="$CC_WRAPPER" ./configure \
  --with-cc="$CC_WRAPPER" \
  --with-cc-opt="${CC_OPT[*]}" \
  --with-ld-opt="" \
  --prefix=/ \
  --conf-path=/nginx.conf \
  --error-log-path=/error.log \
  --http-log-path=/access.log \
  --pid-path=/nginx.pid \
  --lock-path=/nginx.lock \
  --without-http_rewrite_module \
  --without-http_gzip_module \
  --without-http_ssi_module \
  --without-http_userid_module \
  --without-http_auth_basic_module \
  --without-http_autoindex_module \
  --without-http_geo_module \
  --without-http_map_module \
  --without-http_split_clients_module \
  --without-http_referer_module \
  --without-http_proxy_module \
  --without-http_fastcgi_module \
  --without-http_uwsgi_module \
  --without-http_scgi_module

echo "[nginx] build"
make -j"$JOBS"

# ----------------------------------------------------------------------
# 5) Stage output
# ----------------------------------------------------------------------
if [[ ! -f objs/nginx ]]; then
  echo "[nginx] ERROR: expected objs/nginx not found after build" >&2
  exit 1
fi

NGINX_WASM="$OUT_DIR/nginx.wasm"
cp -f objs/nginx "$NGINX_WASM"
echo "[nginx] staged -> $NGINX_WASM"

# ----------------------------------------------------------------------
# 6) wasm-opt (best-effort)
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  OPT_OUT="$OUT_DIR/nginx.opt.wasm"
  echo "[nginx] wasm-opt: nginx.wasm -> nginx.opt.wasm"
  if "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$NGINX_WASM" -o "$OPT_OUT"; then
    echo "[nginx] optimized -> $OPT_OUT"
  else
    echo "[nginx] WARNING: wasm-opt failed; continuing."
  fi
else
  echo "[nginx] NOTE: wasm-opt not found; skipping optimization."
fi

echo "[nginx] done. Outputs under: $OUT_DIR"
ls -lh "$OUT_DIR" || true

