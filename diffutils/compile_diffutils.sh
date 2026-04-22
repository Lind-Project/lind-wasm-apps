#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# diffutils WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU diffutils (cmp, diff, diff3, sdiff) to wasm32-wasi
# using the merged sysroot and toolchain detected by the top-level Makefile
# preflight target.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIFFUTILS_ROOT="$APPS_ROOT/diffutils"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/diffutils/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[diffutils] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# Sanity
if [[ ! -d "$DIFFUTILS_ROOT" ]]; then
  echo "[diffutils] ERROR: diffutils source dir not found at: $DIFFUTILS_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[diffutils] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) WASM toolchain flags
# ----------------------------------------------------------------------
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

echo "[diffutils] using CLANG       = $CLANG"
echo "[diffutils] using AR          = $AR"
echo "[diffutils] using RANLIB      = $RANLIB"
echo "[diffutils] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[diffutils] merged sysroot    = $MERGED_SYSROOT"
echo "[diffutils] stage dir         = $STAGE_DIR"
echo

# ----------------------------------------------------------------------
# 3) Force static-only
# ----------------------------------------------------------------------
export enable_shared=no
export enable_static=yes
export lt_cv_prog_compiler_pic_works=no
export lt_cv_prog_compiler_static_works=yes

export CFLAGS="${CFLAGS:-} ${CFLAGS_WASM[*]}"
export CPPFLAGS="${CPPFLAGS:-} -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
export LDFLAGS="${LDFLAGS:-} ${LDFLAGS_WASM[*]}"

# ----------------------------------------------------------------------
# 4) Prevent autotools regeneration
# ----------------------------------------------------------------------
(
  cd "$DIFFUTILS_ROOT"
  touch aclocal.m4
  touch configure
  find . -name Makefile.in -exec touch {} +
  find . -name '*.info' -exec touch {} +
  find man -name '*.1' 2>/dev/null | xargs -r touch
)

# ----------------------------------------------------------------------
# 5) Configure
# ----------------------------------------------------------------------
BUILD_TRIPLET="$("$DIFFUTILS_ROOT/build-aux/config.guess" 2>/dev/null || echo x86_64-unknown-linux-gnu)"
HOST_TRIPLET="wasm32-unknown-linux-gnu"

echo "[diffutils] configuring..."
(
  cd "$DIFFUTILS_ROOT"
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$HOST_TRIPLET" \
    --disable-nls \
    CC="$CC_WASM" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    CFLAGS="${CFLAGS_WASM[*]}" \
    CPPFLAGS="$CPPFLAGS" \
    LDFLAGS="${LDFLAGS_WASM[*]}" \
    gl_cv_func_strcasecmp_works=yes \
    gl_cv_func_working_mktime=yes
)

if [[ ! -f "$DIFFUTILS_ROOT/Makefile" ]]; then
  echo "[diffutils] ERROR: configure failed before producing Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 6) Build
# ----------------------------------------------------------------------
echo "[diffutils] building..."
make -C "$DIFFUTILS_ROOT" -j"$JOBS" V=1

# ----------------------------------------------------------------------
# 7) Process each binary: stage, wasm-opt, precompile
# ----------------------------------------------------------------------
BINARIES=(cmp diff diff3 sdiff)

if [[ ! -x "$WASM_OPT" ]]; then
  echo "[diffutils] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

if [[ ! -x "$LIND_BOOT" ]]; then
  echo "[diffutils] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

for bin in "${BINARIES[@]}"; do
  SRC_BIN="$DIFFUTILS_ROOT/src/$bin"
  if [[ ! -f "$SRC_BIN" ]]; then
    echo "[diffutils] WARNING: $bin not produced by build, skipping." >&2
    continue
  fi

  BIN_WASM="$SCRIPT_DIR/$bin.wasm"
  BIN_OPT_WASM="$SCRIPT_DIR/$bin.opt.wasm"
  BIN_OPT_CWASM="$SCRIPT_DIR/$bin.opt.cwasm"

  cp "$SRC_BIN" "$BIN_WASM"

  echo "[diffutils] running wasm-opt on $bin..."
  "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo \
    "$BIN_WASM" -o "$BIN_OPT_WASM"

  if [[ ! -f "$BIN_OPT_WASM" ]]; then
    echo "[diffutils] ERROR: Failed to generate $BIN_OPT_WASM" >&2
    exit 1
  fi

  echo "[diffutils] generating cwasm for $bin via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$BIN_OPT_WASM"; then
    if [[ -f "$BIN_OPT_CWASM" ]]; then
      cp "$BIN_OPT_CWASM" "$STAGE_DIR/$bin"
      echo "[diffutils] $bin staged as $STAGE_DIR/$bin"
    else
      echo "[diffutils] ERROR: No .cwasm generated for $bin." >&2
      exit 1
    fi
  else
    echo "[diffutils] ERROR: lind-boot --precompile failed for $bin." >&2
    exit 1
  fi
done

echo
echo "[diffutils] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
