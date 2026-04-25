#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Perl WASI build helper for lind-wasm-apps
#
# Uses perl-cross (https://github.com/arsv/perl-cross) for cross-compilation.
# perl-cross replaces perl's Configure with a cross-compile-friendly version
# that never runs target executables.
#
# Prerequisites:
#   - perl-cross 1.6.4 overlaid on perl 5.40.x source tree
#   - Run 'make preflight' and 'make merge-sysroot' from lind-wasm-apps root
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PERL_ROOT="$APPS_ROOT/perl"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/perl/usr/local/bin"
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
  echo "[perl] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# --- sanity checks -----------------------------------------------------------

if [[ ! -f "$PERL_ROOT/configure" ]]; then
  echo "[perl] ERROR: perl source (with perl-cross overlay) not found at: $PERL_ROOT" >&2
  exit 1
fi

if [[ ! -d "$PERL_ROOT/cnf" ]]; then
  echo "[perl] ERROR: perl-cross overlay not found (missing cnf/ directory)." >&2
  echo "[perl] Hint: overlay perl-cross 1.6.4 onto the perl source tree." >&2
  exit 1
fi

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[perl] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT"

echo "[perl] using CLANG       = $CLANG"
echo "[perl] using AR          = $AR"
echo "[perl] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[perl] merged sysroot    = $MERGED_SYSROOT"
echo "[perl] stage dir         = $STAGE_DIR"
echo

###############################################################################
# Configure with perl-cross
###############################################################################

pushd "$PERL_ROOT" >/dev/null

echo "[perl] cleaning any previous build..."
make distclean >/dev/null 2>&1 || true

echo "[perl] configuring with perl-cross for wasm32-wasi..."
./configure \
  --target=wasm32-unknown-wasi \
  --cc="$CC_WASM" \
  --ar="$AR" \
  --ranlib="$RANLIB" \
  --prefix=/usr/local \
  -Dusedevel \
  -Dcc="$CC_WASM" \
  -Dld="$CC_WASM" \
  -Dar="$AR" \
  -Dranlib="$RANLIB" \
  -Doptimize="-O2 -g" \
  -Dccflags="-pthread -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi" \
  -Dldflags="-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base -L$MERGED_SYSROOT/lib/wasm32-wasi -L$MERGED_SYSROOT/usr/lib/wasm32-wasi" \
  -Dlibs="-lpthread -lm" \
  -Dperllibs="-lpthread -lm" \
  -Uusedl \
  -Uusethreads \
  -Uuseithreads \
  -Uusemultiplicity \
  -Ud_fork \
  -Ud_vfork \
  -Ud_sigaction \
  -Ud_sigprocmask \
  -Ud_alarm \
  -Ud_crypt \
  -Ud_spawn \
  -Ud_aspawn

###############################################################################
# Build
###############################################################################

echo "[perl] building..."
make -j"$JOBS" || {
  echo "[perl] WARNING: build had errors (best-effort, continuing)."
}

PERL_BIN="$PERL_ROOT/perl"
if [[ ! -f "$PERL_BIN" ]]; then
  echo "[perl] ERROR: perl binary not produced." >&2
  exit 1
fi

###############################################################################
# wasm-opt + precompile
###############################################################################

PERL_WASM="$SCRIPT_DIR/perl.wasm"
PERL_OPT_WASM="$SCRIPT_DIR/perl.opt.wasm"
PERL_OPT_CWASM="$SCRIPT_DIR/perl.opt.cwasm"

cp "$PERL_BIN" "$PERL_WASM"

if [[ -x "$WASM_OPT" ]]; then
  echo "[perl] running wasm-opt (asyncify + optimization)..."
  "$WASM_OPT" --epoch-injection --asyncify --fpcast-emu -O2 --debuginfo \
    "$PERL_WASM" -o "$PERL_OPT_WASM"
else
  echo "[perl] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

if [[ ! -f "$PERL_OPT_WASM" ]]; then
  echo "[perl] ERROR: Failed to generate $PERL_OPT_WASM" >&2
  exit 1
fi

if [[ -x "$LIND_BOOT" ]]; then
  echo "[perl] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$PERL_OPT_WASM"; then
    if [[ -f "$PERL_OPT_CWASM" ]]; then
      cp "$PERL_OPT_CWASM" "$STAGE_DIR/perl"
      echo "[perl] perl staged as $STAGE_DIR/perl"
    else
      echo "[perl] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[perl] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[perl] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

popd >/dev/null

echo
echo "[perl] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
