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

# perl-cross requires readelf and objdump for the target. For wasm there are
# no ELF binaries, so we create stubs. But we must NOT put them on PATH
# globally — the native miniperl build needs the real host readelf.
# Instead, pass them explicitly via configure flags for the target only.
STUB_BIN="$PERL_ROOT/.wasi-stubs"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/readelf"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/objdump"
chmod +x "$STUB_BIN/readelf" "$STUB_BIN/objdump"

echo "[perl] configuring with perl-cross for wasm32-wasi..."
# Set target-only tool overrides (buildmini uses HOST* prefix, so these
# only affect the target configure pass)
export READELF="$STUB_BIN/readelf"
export OBJDUMP="$STUB_BIN/objdump"

PERL_EH_CFLAGS=""
if [[ -z "${LIND_ASYNCIFY_SETJMP:-}" ]]; then
  PERL_EH_CFLAGS=" -fwasm-exceptions -mllvm -wasm-enable-sjlj"
fi

CC="$CC_WASM" \
AR="$AR" \
RANLIB="$RANLIB" \
./configure \
  --target=wasm32-unknown-wasi \
  --prefix="/" \
  -Dcc="$CC_WASM" \
  -Dld="$CC_WASM" \
  -Dar="$AR" \
  -Dranlib="$RANLIB" \
  -Doptimize="-O2 -g" \
  -Dccflags="-pthread -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi -Wno-incompatible-function-pointer-types $PERL_EH_CFLAGS" \
  -Dldflags="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base -L$MERGED_SYSROOT/lib/wasm32-wasi -L$MERGED_SYSROOT/usr/lib/wasm32-wasi" \
  -Dlibs="-lpthread -lm" \
  -Dperllibs="-lpthread -lm" \
  -Uusedl \
  -Uusethreads \
  -Uuseithreads \
  -Uusemultiplicity \
  -Dd_fork=define \
  -Ud_vfork \
  -Ud_sigaction \
  -Ud_sigprocmask \
  -Ud_alarm \
  --disable-mod=re \
  -Ud_crypt \
  -Ud_spawn \
  -Ud_aspawn \
  -Dcharsize=1 \
  -Dshortsize=2 \
  -Dintsize=4 \
  -Dlongsize=4 \
  -Ddoublesize=8 \
  -Dptrsize=4 \
  -Dlongdblsize=16 \
  -Dlonglongsize=8 \
  -Dsizesize=4 \
  -Dfpossize=16 \
  -Dlseeksize=8 \
  -Duidsize=4 \
  -Dgidsize=4 \
  -Dtimesize=4 \
  -Dbyteorder=1234

# Fix malformed config.h lines — when a config variable is empty, config_h.SH
# emits "# FOO /**/}" instead of "#define FOO" or "/*#undef FOO*/".
# Treat these as undefined. Use simple comment format to avoid nested /* issues.
if [[ -f config.h ]]; then
  echo "[perl] [wasm] fixing malformed config.h directives..."
  sed -i -E 's|^# ([A-Z_][A-Z_0-9]*)[[:space:]]*/\*\*/$|/* #undef \1 */|' config.h
fi

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

echo "[perl] installing to staging dir..."
make install DESTDIR="$APPS_BUILD/perl" || true

# make install may not install all .pm files (especially from XS extensions
# that failed to build for wasm). Copy them from the source tree as a fallback.
PERL_VER="5.40.4"
PERL_LIB_DEST="$APPS_BUILD/perl/lib/perl5/$PERL_VER"
mkdir -p "$PERL_LIB_DEST"

# Ensure staging dir is writable (perl's installer may set read-only perms)
chmod -R u+w "$APPS_BUILD/perl" 2>/dev/null || true

echo "[perl] copying core lib/ modules..."
rsync -a --no-perms --chmod=u+w --ignore-existing "$PERL_ROOT/lib/" "$PERL_LIB_DEST/"

# Copy extension .pm files from dist/, cpan/, ext/ — these override any
# stubs that make install may have placed.
echo "[perl] copying extension .pm files from dist/..."
find "$PERL_ROOT/dist" -path '*/lib/*.pm' | while read -r f; do
  rel="${f#*dist/*/lib/}"
  mkdir -p "$PERL_LIB_DEST/$(dirname "$rel")"
  cp "$f" "$PERL_LIB_DEST/$rel"
done

echo "[perl] copying extension .pm files from cpan/..."
find "$PERL_ROOT/cpan" -path '*/lib/*.pm' | while read -r f; do
  rel="${f#*cpan/*/lib/}"
  mkdir -p "$PERL_LIB_DEST/$(dirname "$rel")"
  cp "$f" "$PERL_LIB_DEST/$rel"
done

echo "[perl] copying extension .pm files from ext/..."
find "$PERL_ROOT/ext" -path '*/lib/*.pm' | while read -r f; do
  rel="${f#*ext/*/lib/}"
  mkdir -p "$PERL_LIB_DEST/$(dirname "$rel")"
  cp "$f" "$PERL_LIB_DEST/$rel"
done

# Some XS extensions have their .pm at the top of their directory (not under lib/).
# Copy these explicitly — force overwrite to replace any bootstrap stubs.
echo "[perl] copying top-level extension .pm files..."
declare -A EXT_PM_MAP=(
  ["ext/Fcntl/Fcntl.pm"]="Fcntl.pm"
  ["dist/IO/IO.pm"]="IO.pm"
  ["dist/PathTools/Cwd.pm"]="Cwd.pm"
  ["dist/PathTools/lib/File/Spec.pm"]="File/Spec.pm"
  ["dist/PathTools/lib/File/Spec/Unix.pm"]="File/Spec/Unix.pm"
  ["dist/PathTools/lib/File/Spec/Functions.pm"]="File/Spec/Functions.pm"
  ["ext/POSIX/lib/POSIX.pm"]="POSIX.pm"
  ["ext/Socket/Socket.pm"]="Socket.pm"
  ["dist/Storable/Storable.pm"]="Storable.pm"
  ["dist/Data-Dumper/lib/Data/Dumper.pm"]="Data/Dumper.pm"
  ["cpan/IO-Tty/Tty.pm"]="IO/Tty.pm"
  ["cpan/IO-Tty/Pty.pm"]="IO/Pty.pm"
  ["cpan/IO-Tty/Tty/Constant.pm"]="IO/Tty/Constant.pm"
)
for src_rel in "${!EXT_PM_MAP[@]}"; do
  src="$PERL_ROOT/$src_rel"
  dest="$PERL_LIB_DEST/${EXT_PM_MAP[$src_rel]}"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  fi
done

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
