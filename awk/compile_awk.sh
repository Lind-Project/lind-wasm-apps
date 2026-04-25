#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# gawk WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU awk (gawk) to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWK_ROOT="$APPS_ROOT/awk"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/awk/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# --- load toolchain ----------------------------------------------------------

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[awk] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$AWK_ROOT" ]]; then
  echo "[awk] ERROR: awk source dir not found at: $AWK_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[awk] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# --- WASM toolchain flags ----------------------------------------------------

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

LDFLAGS_WASM=(
  "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
  -L"$MERGED_SYSROOT/lib/wasm32-wasi"
  -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
)

echo "[awk] using CLANG       = $CLANG"
echo "[awk] using AR          = $AR"
echo "[awk] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[awk] merged sysroot    = $MERGED_SYSROOT"
echo "[awk] stage dir         = $STAGE_DIR"
echo

# --- force static-only -------------------------------------------------------

export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# --- prevent autotools regeneration ------------------------------------------

(
  cd "$AWK_ROOT"
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' 2>/dev/null | xargs -r touch
)

# --- configure ---------------------------------------------------------------

BUILD_TRIPLET="$("$AWK_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[awk] configuring..."
(
  cd "$AWK_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    --disable-extensions \
    --without-readline \
    --without-mpfr \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}"
)

if [[ ! -f "$AWK_ROOT/Makefile" ]]; then
  echo "[awk] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

echo "[awk] building..."
make -C "$AWK_ROOT" -j"$JOBS" V=1

# --- stage, wasm-opt, precompile --------------------------------------------

AWK_BIN="$AWK_ROOT/gawk"
if [[ ! -f "$AWK_BIN" ]]; then
  echo "[awk] ERROR: gawk binary not found after build." >&2
  exit 1
fi

AWK_WASM="$SCRIPT_DIR/gawk.wasm"
AWK_OPT_WASM="$SCRIPT_DIR/gawk.opt.wasm"
AWK_OPT_CWASM="$SCRIPT_DIR/gawk.opt.cwasm"

cp "$AWK_BIN" "$AWK_WASM"

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[awk] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

echo "[awk] running wasm-opt (asyncify + optimization)..."
"$WASM_OPT" --epoch-injection --asyncify --fpcast-emu -O2 --debuginfo \
  "$AWK_WASM" -o "$AWK_OPT_WASM"

if [[ ! -f "$AWK_OPT_WASM" ]]; then
  echo "[awk] ERROR: Failed to generate $AWK_OPT_WASM" >&2
  exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
  echo "[awk] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$AWK_OPT_WASM"; then
    if [[ -f "$AWK_OPT_CWASM" ]]; then
      cp "$AWK_OPT_CWASM" "$STAGE_DIR/gawk"
      echo "[awk] gawk staged as $STAGE_DIR/gawk"
    else
      echo "[awk] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[awk] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[awk] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

echo
echo "[awk] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# gawk WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU awk (gawk) to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWK_ROOT="$APPS_ROOT/awk"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/awk/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# --- load toolchain ----------------------------------------------------------

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[awk] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$AWK_ROOT" ]]; then
  echo "[awk] ERROR: awk source dir not found at: $AWK_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[awk] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# --- WASM toolchain flags ----------------------------------------------------

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

CFLAGS_WASM=(
  -O2 -g -std=gnu99 -pthread
  -I"$MERGED_SYSROOT/include"
  -I"$MERGED_SYSROOT/include/wasm32-wasi"
)

LDFLAGS_WASM=(
  "-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
  -L"$MERGED_SYSROOT/lib/wasm32-wasi"
  -L"$MERGED_SYSROOT/usr/lib/wasm32-wasi"
)

echo "[awk] using CLANG       = $CLANG"
echo "[awk] using AR          = $AR"
echo "[awk] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[awk] merged sysroot    = $MERGED_SYSROOT"
echo "[awk] stage dir         = $STAGE_DIR"
echo

# --- force static-only -------------------------------------------------------

export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# --- prevent autotools regeneration ------------------------------------------

(
  cd "$AWK_ROOT"
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' 2>/dev/null | xargs -r touch
)

# --- configure ---------------------------------------------------------------

BUILD_TRIPLET="$("$AWK_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[awk] configuring..."
(
  cd "$AWK_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    --disable-extensions \
    --without-readline \
    --without-mpfr \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}"
)

if [[ ! -f "$AWK_ROOT/Makefile" ]]; then
  echo "[awk] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

echo "[awk] building..."
make -C "$AWK_ROOT" -j"$JOBS" V=1

# --- stage, wasm-opt, precompile --------------------------------------------

AWK_BIN="$AWK_ROOT/gawk"
if [[ ! -f "$AWK_BIN" ]]; then
  echo "[awk] ERROR: gawk binary not found after build." >&2
  exit 1
fi

AWK_WASM="$SCRIPT_DIR/gawk.wasm"
AWK_OPT_WASM="$SCRIPT_DIR/gawk.opt.wasm"
AWK_OPT_CWASM="$SCRIPT_DIR/gawk.opt.cwasm"

cp "$AWK_BIN" "$AWK_WASM"

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[awk] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

echo "[awk] running wasm-opt (asyncify + optimization)..."
"$WASM_OPT" --epoch-injection --asyncify --fpcast-emu -O2 --debuginfo \
  "$AWK_WASM" -o "$AWK_OPT_WASM"

if [[ ! -f "$AWK_OPT_WASM" ]]; then
  echo "[awk] ERROR: Failed to generate $AWK_OPT_WASM" >&2
  exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
  echo "[awk] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$AWK_OPT_WASM"; then
    if [[ -f "$AWK_OPT_CWASM" ]]; then
      cp "$AWK_OPT_CWASM" "$STAGE_DIR/gawk"
      echo "[awk] gawk staged as $STAGE_DIR/gawk"
    else
      echo "[awk] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[awk] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[awk] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

echo
echo "[awk] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
