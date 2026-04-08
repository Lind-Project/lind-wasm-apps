#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Binutils WASI build helper for lind-wasm-apps
#
# Cross-compiles GNU Binutils 2.46.0 (ld, as) to wasm32-wasi so that the
# linker and assembler can run inside the Lind sandbox alongside cc1 from GCC.
# The resulting tools target x86_64-linux-gnu (matching GCC's --target).
#
# High-level strategy:
#   1. Out-of-tree build
#   2. Configure with --host=wasm32-unknown-wasi, --target=x86_64-linux-gnu
#      Generator tools are built natively via CC_FOR_BUILD; ld/as are cross-
#      compiled to wasm32 via CC.
#   3. Build with 'make all-ld all-gas' (linker + assembler only)
#   4. Stage ld and as, post-process with wasm-opt + lind-boot
#
# Prerequisites:
#   - Run 'make preflight merge-sysroot' first
#   - Native gcc must be on PATH (for CC_FOR_BUILD)
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINUTILS_SRC="$APPS_ROOT/binutils"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/binutils/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

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
  echo "[binutils] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"
: "${NM:?missing NM in $TOOL_ENV}"

# Sanity checks
if [[ ! -d "$BINUTILS_SRC" ]]; then
  echo "[binutils] ERROR: source dir not found at '$BINUTILS_SRC'" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[binutils] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi
if ! command -v gcc &>/dev/null; then
  echo "[binutils] ERROR: native gcc required for CC_FOR_BUILD but not found on PATH" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) WASM toolchain flags
# ----------------------------------------------------------------------
CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT \
  -pthread -matomics -mbulk-memory \
  -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"

CFLAGS_WASM="-Os"

LDFLAGS_WASM="-Wl,--import-memory,--export-memory,--max-memory=67108864 \
  -Wl,--export=__stack_pointer,--export=__stack_low \
  -L$MERGED_SYSROOT/lib/wasm32-wasi \
  -L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

echo "[binutils] using CLANG          = $CLANG"
echo "[binutils] using AR             = $AR"
echo "[binutils] LIND_WASM_ROOT       = $LIND_WASM_ROOT"
echo "[binutils] merged sysroot       = $MERGED_SYSROOT"
echo "[binutils] stage dir            = $STAGE_DIR"
echo "[binutils] CC_WASM              = $CC_WASM"
echo

# ----------------------------------------------------------------------
# 3) Out-of-tree build directory
# ----------------------------------------------------------------------
BINUTILS_BUILD="$APPS_BUILD/binutils-build"
mkdir -p "$BINUTILS_BUILD"

echo "[binutils] build dir = $BINUTILS_BUILD"

# ----------------------------------------------------------------------
# 4) Configure
# ----------------------------------------------------------------------
BUILD_TRIPLET="$(gcc -dumpmachine 2>/dev/null || echo x86_64-linux-gnu)"

echo "[binutils] configuring…"
echo "[binutils]   --build=$BUILD_TRIPLET"
echo "[binutils]   --host=wasm32-unknown-wasi"
echo "[binutils]   --target=x86_64-linux-gnu"

pushd "$BINUTILS_BUILD" >/dev/null

"$BINUTILS_SRC/configure" \
  --build="$BUILD_TRIPLET" \
  --host=wasm32-unknown-wasi \
  --target=x86_64-linux-gnu \
  --disable-shared \
  --enable-static \
  --disable-nls \
  --disable-plugins \
  --disable-gdb \
  --disable-gdbserver \
  --disable-gprofng \
  --disable-sim \
  --disable-gold \
  --enable-ld=yes \
  --disable-werror \
  --disable-largefile \
  --without-zstd \
  --with-system-zlib \
  CC_FOR_BUILD=gcc \
  AR_FOR_BUILD=ar \
  CFLAGS_FOR_BUILD="-O2 -g" \
  LDFLAGS_FOR_BUILD="" \
  CC="$CC_WASM" \
  AR="$AR" \
  NM="$NM" \
  RANLIB="$RANLIB" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM"

if [[ ! -f Makefile ]]; then
  echo "[binutils] ERROR: configure failed to produce Makefile." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 5) Build ld and as
# ----------------------------------------------------------------------
echo "[binutils] building (make all-ld all-gas)…"
make all-ld all-gas -j"$JOBS" V=1 MAKEINFO=true

popd >/dev/null

# ----------------------------------------------------------------------
# 6) Post-process helper
# ----------------------------------------------------------------------
post_process_binary() {
  local NAME="$1"
  local SRC_BIN="$2"

  if [[ ! -f "$SRC_BIN" ]]; then
    echo "[binutils] ERROR: $NAME binary not produced at '$SRC_BIN'" >&2
    return 1
  fi

  local WASM_FILE="$SCRIPT_DIR/${NAME}.wasm"
  local OPT_WASM="$SCRIPT_DIR/${NAME}.opt.wasm"
  cp "$SRC_BIN" "$WASM_FILE"
  echo "[binutils] $NAME binary size: $(du -h "$WASM_FILE" | cut -f1)"

  # --- wasm-opt ---
  if [[ -x "$WASM_OPT" ]]; then
    echo "[binutils] running wasm-opt on $NAME (epoch-injection + asyncify + O2)…"
    "$WASM_OPT" --epoch-injection --asyncify \
      --debuginfo -O2 \
      "$WASM_FILE" -o "$OPT_WASM"
  else
    echo "[binutils] ERROR: wasm-opt not found at '$WASM_OPT'; exiting." >&2
    exit 1
  fi

  if [[ ! -f "$OPT_WASM" ]]; then
    echo "[binutils] ERROR: failed to generate '$OPT_WASM'; exiting." >&2
    exit 1
  fi

  # --- lind-boot --precompile ---
  if [[ ! -x "$LIND_BOOT" ]]; then
    echo "[binutils] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
    exit 1
  fi

  echo "[binutils] generating cwasm for $NAME via lind-boot --precompile…"
  "$LIND_BOOT" --precompile "$OPT_WASM"

  local OPT_CWASM="$SCRIPT_DIR/${NAME}.opt.cwasm"
  if [[ ! -f "$OPT_CWASM" ]]; then
    echo "[binutils] ERROR: precompile produced no .cwasm for $NAME" >&2
    exit 1
  fi

  cp "$OPT_CWASM" "$STAGE_DIR/$NAME"
  echo "[binutils] $NAME staged as $STAGE_DIR/$NAME (precompiled)"
}

# ----------------------------------------------------------------------
# 7) Stage ld and as
# ----------------------------------------------------------------------
LD_BIN="$BINUTILS_BUILD/ld/ld-new"
AS_BIN="$BINUTILS_BUILD/gas/as-new"

post_process_binary "ld" "$LD_BIN"
post_process_binary "as" "$AS_BIN"

popd >/dev/null 2>&1 || true

echo
echo "[binutils] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
