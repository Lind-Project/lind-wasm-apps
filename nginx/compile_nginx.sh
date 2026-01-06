#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Nginx WASM build helper for lind-wasm-apps
#
# Strategy:
#   1) Load toolchain from build/.toolchain.env (set by top-level Makefile preflight).
#   2) Locate Lind's wasmtime (used to run nginx configure-time probe programs).
#   3) Copy vendored nginx source into build/nginx-src (keep repo clean).
#   4) Patch nginx auto scripts so configure runs probe binaries via wasmtime
#      instead of executing wasm directly (avoids "Exec format error").
#   5) Configure + build with wasm32-wasi toolchain against merged sysroot.
#   6) Stage build/bin/nginx/wasm32-wasi/nginx.wasm
#   7) Best-effort wasm-opt + wasmtime compile -> nginx.opt.wasm / nginx.cwasm
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

# ----------------------------------------------------------------------
# 2) Locate wasmtime (match lmbench/bash convention)
# ----------------------------------------------------------------------
WASMTIME_PROFILE="${WASMTIME_PROFILE:-release}"
WASMTIME="${WASMTIME:-$LIND_WASM_ROOT/src/wasmtime/target/${WASMTIME_PROFILE}/wasmtime}"

# Fallback to release if the requested profile isn't built yet.
if [[ ! -x "$WASMTIME" ]]; then
  ALT="$LIND_WASM_ROOT/src/wasmtime/target/release/wasmtime"
  [[ -x "$ALT" ]] && WASMTIME="$ALT"
fi

if [[ ! -x "$WASMTIME" ]]; then
  echo "[nginx] ERROR: wasmtime not found at:" >&2
  echo "        $LIND_WASM_ROOT/src/wasmtime/target/${WASMTIME_PROFILE}/wasmtime" >&2
  echo "        (and no release fallback found)" >&2
  echo "[nginx] Hint: run 'make wasmtime' in lind-wasm, or export WASMTIME=/path/to/wasmtime." >&2
  exit 1
fi

# Configure-time probe runner (nginx configure runs objs/autotest)
export NGX_WASM_RUNNER="$WASMTIME --dir=."
echo "[nginx] using NGX_WASM_RUNNER = $NGX_WASM_RUNNER"

# Optional post-processing tools (best-effort)
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"

# ----------------------------------------------------------------------
# 3) Copy vendored nginx source into build/ (keep repo clean)
# ----------------------------------------------------------------------
echo "[nginx] preparing source copy -> $WORK_SRC"
rm -rf "$WORK_SRC"
mkdir -p "$WORK_SRC"
rsync -a --delete "$REPO_ROOT/nginx/" "$WORK_SRC/"

cd "$WORK_SRC"

# ----------------------------------------------------------------------
# 4) Patch nginx auto scripts to run autotests via NGX_WASM_RUNNER
#    (use awk for deterministic, non-fragile patching)
# ----------------------------------------------------------------------
echo "[nginx] patching auto scripts to run configure probes via NGX_WASM_RUNNER"

# ---- Patch auto/types/sizeof ----
# Replace the single line: ngx_size=`$NGX_AUTOTEST`
# with a runner-aware block that uses NGX_WASM_RUNNER when set.
awk '
{
  if ($0 ~ /^[[:space:]]*ngx_size=`\$NGX_AUTOTEST`[[:space:]]*$/) {
    print "    if [ -n \"\\$NGX_WASM_RUNNER\" ]; then"
    print "        ngx_size=`\\$NGX_WASM_RUNNER \\$NGX_AUTOTEST`"
    print "    else"
    print "        ngx_size=`\\$NGX_AUTOTEST`"
    print "    fi"
    next
  }
  print
}
' auto/types/sizeof > auto/types/sizeof.new
mv auto/types/sizeof.new auto/types/sizeof
chmod +x auto/types/sizeof

# Sanity check: if this fails, stop and show the file section
if ! grep -n "NGX_WASM_RUNNER" auto/types/sizeof >/dev/null; then
  echo "[nginx] ERROR: failed to patch auto/types/sizeof (no NGX_WASM_RUNNER reference found)"
  echo "[nginx] ---- auto/types/sizeof (first 140 lines) ----"
  sed -n '1,140p' auto/types/sizeof
  exit 1
fi

# ---- Patch auto/feature ----
# 1) Inject ngx_autotest_cmd after: if [ -x $NGX_AUTOTEST ]; then
# 2) Replace /bin/sh -c $NGX_AUTOTEST with /bin/sh -c "$ngx_autotest_cmd"
# 3) Replace backtick `$NGX_AUTOTEST` in the value-probe define with runner
awk '
{
  if ($0 ~ /^if \[ -x \$NGX_AUTOTEST \ ]; then$/) {
    print $0
    print ""
    print "    # When cross-compiling to wasm32-wasi, $NGX_AUTOTEST is a WASM module."
    print "    # Running it directly will fail with \"Exec format error\"."
    print "    ngx_autotest_cmd=\"$NGX_AUTOTEST\""
    print "    if [ -n \"$NGX_WASM_RUNNER\" ]; then"
    print "        ngx_autotest_cmd=\"$NGX_WASM_RUNNER $NGX_AUTOTEST\""
    print "    fi"
    next
  }

  gsub(/\/bin\/sh -c \$NGX_AUTOTEST/, "/bin/sh -c \"\\$ngx_autotest_cmd\"")

  # Replace the backtick execution used in the value-probe define
  gsub(/`\\$NGX_AUTOTEST`/, "` /bin/sh -c \"\\$ngx_autotest_cmd\" `")

  print
}
' auto/feature > auto/feature.new
mv auto/feature.new auto/feature
chmod +x auto/feature

if ! grep -n "ngx_autotest_cmd" auto/feature >/dev/null; then
  echo "[nginx] ERROR: failed to patch auto/feature (no ngx_autotest_cmd found)"
  exit 1
fi

# ----------------------------------------------------------------------
# 5) Configure + build (baseline minimal modules first)
# ----------------------------------------------------------------------
TARGET="wasm32-unknown-wasi"
CC_OPT=(
  "--target=$TARGET"
  "--sysroot=$MERGED_SYSROOT"
  "-O2"
  "-g0"
)
LD_OPT=(
  "--target=$TARGET"
  "--sysroot=$MERGED_SYSROOT"
)

echo "[nginx] configure (baseline, minimal modules)"
./configure \
  --with-cc="$CLANG" \
  --with-cc-opt="${CC_OPT[*]}" \
  --with-ld-opt="${LD_OPT[*]}" \
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
# 6) Stage output
# ----------------------------------------------------------------------
if [[ ! -f objs/nginx ]]; then
  echo "[nginx] ERROR: expected objs/nginx not found after build" >&2
  exit 1
fi

NGINX_WASM="$OUT_DIR/nginx.wasm"
cp -f objs/nginx "$NGINX_WASM"
echo "[nginx] staged -> $NGINX_WASM"

# ----------------------------------------------------------------------
# 7) wasm-opt + wasmtime compile (best-effort)
# ----------------------------------------------------------------------
BIN_FOR_COMPILE="$NGINX_WASM"

if [[ -x "$WASM_OPT" ]]; then
  OPT_OUT="$OUT_DIR/nginx.opt.wasm"
  echo "[nginx] wasm-opt: nginx.wasm -> nginx.opt.wasm"
  if "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$NGINX_WASM" -o "$OPT_OUT"; then
    BIN_FOR_COMPILE="$OPT_OUT"
  else
    echo "[nginx] WARNING: wasm-opt failed; continuing with unoptimized binary."
  fi
else
  echo "[nginx] NOTE: wasm-opt not found; skipping optimization."
fi

if [[ -x "$WASMTIME" ]]; then
  CWASM_OUT="$OUT_DIR/nginx.cwasm"
  echo "[nginx] wasmtime compile: -> nginx.cwasm"
  "$WASMTIME" compile "$BIN_FOR_COMPILE" -o "$CWASM_OUT" || \
    echo "[nginx] WARNING: wasmtime compile failed; continuing."
fi

echo "[nginx] done. Outputs under: $OUT_DIR"
ls -lh "$OUT_DIR" || true

