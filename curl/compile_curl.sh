#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# curl WASI build helper for lind-wasm-apps
#
# Cross-compiles curl for wasm32-wasi with OpenSSL and zlib (both already
# present in the merged sysroot). Only HTTP/HTTPS protocols are enabled;
# everything else is disabled to minimise surface area and link complexity.
#
# Supports both Static (default) and Dynamic (LIND_DYLINK=1) builds.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CURL_ROOT="$APPS_ROOT/curl"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/curl/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[curl] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$CURL_ROOT" ]]; then
  echo "[curl] ERROR: curl source dir not found at: $CURL_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[curl] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) Base WASM Toolchain Flags
# ----------------------------------------------------------------------
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

# ----------------------------------------------------------------------
# 3) Branch Logic: Dynamic vs Static Settings
# ----------------------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[curl] Mode: DYNAMIC LINKING (LIND_DYLINK=1)"
  CFLAGS_WASM+=(-fPIC)

  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[curl] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  DYLINK_CRT_OBJS=(
    "$MERGED_SYSROOT/lib/wasm32-wasi/set_stack_pointer.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[curl] ERROR: required dylink CRT object '$obj' not found." >&2
      exit 1
    fi
  done

  # Flags for the actual build phase
  LDFLAGS_WASM=(
    "-nostartfiles"
    "-Wl,-pie"
    "-Wl,--import-table"
    "-Wl,--import-memory"
    "-Wl,--export-memory"
    "-Wl,--shared-memory"
    "-Wl,--max-memory=67108864"
    "-Wl,--allow-undefined"
    "-Wl,--unresolved-symbols=import-dynamic"
    "-Wl,--export=__wasm_call_ctors"
    "-Wl,--export-if-defined=__wasm_init_tls"
    "-Wl,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
    "${DYLINK_CRT_OBJS[@]}"
  )
  
  # Flags just for ./configure (to pass autoconf feature tests)
  LDFLAGS_CONFIGURE=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )

  # Libtool: Build a Static library, but force it to contain PIC objects
  # so it can be safely linked into our dynamic PIE executable later.
  export enable_shared=no
  export enable_static=yes
  export lt_cv_prog_compiler_pic_works=yes
  export lt_cv_prog_compiler_static_works=yes
  CONFIG_SHARED_FLAGS="--disable-shared --enable-static"
else
  echo "[curl] Mode: STATIC LINKING (LIND_DYLINK=0 or unset)"
  
  LDFLAGS_WASM=(
    "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
    -L"$MERGED_SYSROOT/lib/wasm32-wasi"
    -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
  )
  LDFLAGS_CONFIGURE=("${LDFLAGS_WASM[@]}")

  # Libtool & Configure variables for Static Libraries
  export enable_shared=no
  export enable_static=yes
  export lt_cv_prog_compiler_pic_works=no
  export lt_cv_prog_compiler_static_works=yes
  CONFIG_SHARED_FLAGS="--disable-shared --enable-static"
fi

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_CONFIGURE[*]}"

# ----------------------------------------------------------------------
# 4) autoreconf (generate configure from configure.ac)
# ----------------------------------------------------------------------
cd "$CURL_ROOT"

echo "[curl] cleaning previous build artifacts…"
make distclean 2>/dev/null || true

echo "[curl] running autoreconf -fi…"
autoreconf -fi

# ----------------------------------------------------------------------
# 5) Configure
# ----------------------------------------------------------------------
echo "[curl] configuring…"

# shellcheck disable=SC2086 # Intentionally splitting CONFIG_SHARED_FLAGS
./configure \
  --build="$(./config.guess)" \
  --host=wasm32-unknown-linux-gnu \
  $CONFIG_SHARED_FLAGS --disable-libtool-lock \
  --with-openssl --with-zlib \
  --without-libssh2 --without-libssh --without-brotli --without-zstd \
  --without-libpsl --without-nghttp2 --without-librtmp --without-gssapi \
  --without-gsasl --without-libidn2 --without-winidn \
  --disable-ftp --disable-file --disable-ldap --disable-ldaps \
  --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
  --disable-pop3 --disable-imap --disable-smb --disable-smtp \
  --disable-gopher --disable-mqtt --disable-ipfs \
  --enable-http --enable-proxy --disable-ipv6 \
  --disable-manual --disable-docs --disable-threaded-resolver \
  --disable-websockets --disable-openssl-auto-load-config \
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  CFLAGS="${CFLAGS_WASM[*]}" \
  CPPFLAGS="$CPPFLAGS" \
  LDFLAGS="${LDFLAGS_CONFIGURE[*]}" \
  LIBS="-lssl -lcrypto -lz" \
  PKG_CONFIG=false \
  curl_cv_writable_argv=yes

# ----------------------------------------------------------------------
# 6) Build
# ----------------------------------------------------------------------
echo "[curl] building…"

# Inject the true Wasm LDFLAGS and CFLAGS for the make step
make -j"$JOBS" V=1 \
  CFLAGS="${CFLAGS_WASM[*]}" \
  LDFLAGS="${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 7) Stage binary
# ----------------------------------------------------------------------
echo "[curl] staging binary…"

# libtool puts the real binary in src/.libs/curl; fall back to src/curl
CURL_BIN=""
for candidate in "$CURL_ROOT/src/.libs/curl" "$CURL_ROOT/src/curl"; do
  if [[ -f "$candidate" ]]; then
    CURL_BIN="$candidate"
    break
  fi
done

if [[ -z "$CURL_BIN" ]]; then
  echo "[curl] ERROR: curl binary not found in src/.libs/curl or src/curl" >&2
  exit 1
fi

CURL_WASM="$SCRIPT_DIR/curl.wasm"
CURL_OPT_WASM="$SCRIPT_DIR/curl.opt.wasm"
cp "$CURL_BIN" "$CURL_WASM"

# ----------------------------------------------------------------------
# 8) wasm-opt & exports
# ----------------------------------------------------------------------
if [[ -x "$WASM_OPT" ]]; then
  echo "[curl] running wasm-opt (asyncify + optimization)…"
  if [[ "$LIND_DYLINK" == "1" ]]; then
    "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
      --asyncify --pass-arg=asyncify-import-globals \
      -O2 --debuginfo \
      "$CURL_WASM" -o "$CURL_OPT_WASM"
  else
    "$WASM_OPT" \
      --epoch-injection \
      --asyncify \
      -O2 --debuginfo \
      "$CURL_WASM" -o "$CURL_OPT_WASM"
  fi
else
  echo "[curl] ERROR: wasm-opt not found at '$WASM_OPT'; skipping optimization. Exiting.."
  exit 1
fi

if [[ ! -f "$CURL_OPT_WASM" ]]; then
  echo "[curl] ERROR: Failed to generate $CURL_OPT_WASM; Exiting.."
  exit 1
fi

# Add dylink exports if dynamic linking is enabled
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[curl] adding dylink exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$CURL_OPT_WASM" "$CURL_OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$CURL_OPT_WASM" "$CURL_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$CURL_OPT_WASM" "$CURL_OPT_WASM" __stack_pointer global __stack_pointer
fi

# ----------------------------------------------------------------------
# 9) cwasm generation (best-effort) via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[curl] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$CURL_OPT_WASM"; then
   
    CURL_OPT_CWASM="$SCRIPT_DIR/curl.opt.cwasm"

    # Stage the final .cwasm binary
    if [[ -f "$CURL_OPT_CWASM" ]]; then
      cp "$CURL_OPT_CWASM" "$STAGE_DIR/curl"
      echo "[curl] curl staged as $STAGE_DIR/curl"
    else
      echo "[curl] ERROR: No .cwasm binary generated and no binaries copied to the build folder. Exiting.. "
      exit 1
    fi
  else
    echo "[curl] ERROR: lind-boot --precompile failed; skipping cwasm generation."
    exit 1
  fi
else
  echo "[curl] ERROR: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  exit 1
fi

# ----------------------------------------------------------------------
# 10) Stage CA certificate bundle
# ----------------------------------------------------------------------
CA_BUNDLE_DEST="$APPS_BUILD/curl/etc/ssl/certs"
mkdir -p "$CA_BUNDLE_DEST"
if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
  cp /etc/ssl/certs/ca-certificates.crt "$CA_BUNDLE_DEST/ca-certificates.crt"
  echo "[curl] CA bundle staged to $CA_BUNDLE_DEST"
else
  echo "[curl] WARNING: /etc/ssl/certs/ca-certificates.crt not found on host; HTTPS may fail at runtime."
fi

echo
echo "[curl] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
