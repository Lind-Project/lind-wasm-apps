#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# GNU make WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU make to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAKE_ROOT="$APPS_ROOT/make"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/make/usr/local/bin"
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
  echo "[make] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$MAKE_ROOT" ]]; then
  echo "[make] ERROR: make source dir not found at: $MAKE_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[make] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
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

echo "[make] using CLANG       = $CLANG"
echo "[make] using AR          = $AR"
echo "[make] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[make] merged sysroot    = $MERGED_SYSROOT"
echo "[make] stage dir         = $STAGE_DIR"
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
  cd "$MAKE_ROOT"
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' 2>/dev/null | xargs -r touch
)

# --- configure ---------------------------------------------------------------

BUILD_TRIPLET="$("$MAKE_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[make] configuring..."
(
  cd "$MAKE_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    --disable-load \
    --without-guile \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}"
)

if [[ ! -f "$MAKE_ROOT/Makefile" ]]; then
  echo "[make] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

echo "[make] building..."
make -C "$MAKE_ROOT" -j"$JOBS" V=1

# --- stage, wasm-opt, precompile --------------------------------------------

MAKE_BIN="$MAKE_ROOT/make"
if [[ ! -f "$MAKE_BIN" ]]; then
  echo "[make] ERROR: make binary not found after build." >&2
  exit 1
fi

MAKE_WASM="$SCRIPT_DIR/make.wasm"
MAKE_OPT_WASM="$SCRIPT_DIR/make.opt.wasm"
MAKE_OPT_CWASM="$SCRIPT_DIR/make.opt.cwasm"

cp "$MAKE_BIN" "$MAKE_WASM"

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[make] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

echo "[make] running wasm-opt (asyncify + optimization)..."
"$WASM_OPT" --epoch-injection --asyncify --fpcast-emu -O2 --debuginfo \
  "$MAKE_WASM" -o "$MAKE_OPT_WASM"

if [[ ! -f "$MAKE_OPT_WASM" ]]; then
  echo "[make] ERROR: Failed to generate $MAKE_OPT_WASM" >&2
  exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
  echo "[make] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$MAKE_OPT_WASM"; then
    if [[ -f "$MAKE_OPT_CWASM" ]]; then
      cp "$MAKE_OPT_CWASM" "$STAGE_DIR/make"
      echo "[make] make staged as $STAGE_DIR/make"
    else
      echo "[make] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[make] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[make] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

echo
echo "[make] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# GNU make WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU make to wasm32-wasi using the merged sysroot and
# toolchain detected by the top-level Makefile preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAKE_ROOT="$APPS_ROOT/make"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/make/usr/local/bin"
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
  echo "[make] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

if [[ ! -d "$MAKE_ROOT" ]]; then
  echo "[make] ERROR: make source dir not found at: $MAKE_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[make] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
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

echo "[make] using CLANG       = $CLANG"
echo "[make] using AR          = $AR"
echo "[make] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[make] merged sysroot    = $MERGED_SYSROOT"
echo "[make] stage dir         = $STAGE_DIR"
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
  cd "$MAKE_ROOT"
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  find . -name '*.info' -exec touch {} +
  find doc -name '*.1' 2>/dev/null | xargs -r touch
)

# --- configure ---------------------------------------------------------------

BUILD_TRIPLET="$("$MAKE_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[make] configuring..."
(
  cd "$MAKE_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    --disable-load \
    --without-guile \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}"
)

if [[ ! -f "$MAKE_ROOT/Makefile" ]]; then
  echo "[make] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

echo "[make] building..."
make -C "$MAKE_ROOT" -j"$JOBS" V=1

# --- stage, wasm-opt, precompile --------------------------------------------

MAKE_BIN="$MAKE_ROOT/make"
if [[ ! -f "$MAKE_BIN" ]]; then
  echo "[make] ERROR: make binary not found after build." >&2
  exit 1
fi

MAKE_WASM="$SCRIPT_DIR/make.wasm"
MAKE_OPT_WASM="$SCRIPT_DIR/make.opt.wasm"
MAKE_OPT_CWASM="$SCRIPT_DIR/make.opt.cwasm"

cp "$MAKE_BIN" "$MAKE_WASM"

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[make] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

echo "[make] running wasm-opt (asyncify + optimization)..."
"$WASM_OPT" --epoch-injection --asyncify --fpcast-emu -O2 --debuginfo \
  "$MAKE_WASM" -o "$MAKE_OPT_WASM"

if [[ ! -f "$MAKE_OPT_WASM" ]]; then
  echo "[make] ERROR: Failed to generate $MAKE_OPT_WASM" >&2
  exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
  echo "[make] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$MAKE_OPT_WASM"; then
    if [[ -f "$MAKE_OPT_CWASM" ]]; then
      cp "$MAKE_OPT_CWASM" "$STAGE_DIR/make"
      echo "[make] make staged as $STAGE_DIR/make"
    else
      echo "[make] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[make] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[make] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

echo
echo "[make] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
