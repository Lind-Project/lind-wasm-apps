#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Perl WASI build helper for lind-wasm-apps
#
# Two-pass build strategy:
#   Pass 1 (native):  Build miniperl on the host — required for running
#                      configuration scripts and generating headers.
#   Pass 2 (WASM):    Cross-compile perl for wasm32-wasi using the native
#                      miniperl and a pre-populated config.sh.
#
# Prerequisites:
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

if [[ ! -f "$PERL_ROOT/Configure" ]]; then
  echo "[perl] ERROR: perl source not found at: $PERL_ROOT" >&2
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
# Pass 1: Build native miniperl
###############################################################################

echo "[perl] ============================================"
echo "[perl] Pass 1: Native build (miniperl)"
echo "[perl] ============================================"

NATIVE_BUILD_DIR="$PERL_ROOT/build-native"

if [[ -x "$NATIVE_BUILD_DIR/miniperl" ]]; then
  echo "[perl] native miniperl already built, reusing."
else
  mkdir -p "$NATIVE_BUILD_DIR"
  pushd "$PERL_ROOT" >/dev/null

  # Clean any previous in-tree build
  make distclean >/dev/null 2>&1 || true

  echo "[perl] [host] configuring (native)..."
  sh Configure \
    -des \
    -Dusedevel \
    -Dprefix="$NATIVE_BUILD_DIR/install" \
    -Uusethreads

  echo "[perl] [host] building miniperl and generate_uudmap..."
  make -j"$JOBS" miniperl generate_uudmap

  # Save native tools and generated files before we clean for wasm
  cp miniperl "$NATIVE_BUILD_DIR/miniperl"
  cp generate_uudmap "$NATIVE_BUILD_DIR/generate_uudmap"
  cp config.sh "$NATIVE_BUILD_DIR/config.sh.native"
  cp config.h "$NATIVE_BUILD_DIR/config.h.native"

  # Generate the headers that generate_uudmap produces (bitcount.h, etc.)
  # so they're available for the wasm build
  make bitcount.h
  cp bitcount.h mg_data.h uudmap.h "$NATIVE_BUILD_DIR/" 2>/dev/null || true

  popd >/dev/null
fi

MINIPERL="$NATIVE_BUILD_DIR/miniperl"
echo "[perl] native miniperl: $MINIPERL"

###############################################################################
# Pass 2: Cross-compile for wasm32-wasi
###############################################################################

echo "[perl] ============================================"
echo "[perl] Pass 2: WASM cross-compile"
echo "[perl] ============================================"

pushd "$PERL_ROOT" >/dev/null

# Full distclean to remove stale config (ensure new config.sh overrides take effect)
echo "[perl] [wasm] cleaning previous build..."
make distclean >/dev/null 2>&1 || true

# --- Generate config.sh for wasm32-wasi ------------------------------------

# Perl's Configure is interactive and tries to run test programs, which
# doesn't work for cross-compilation to WASI. Instead, we generate a
# config.sh with the right values pre-populated.

echo "[perl] [wasm] generating config.sh for wasm32-wasi..."

WASM_CFLAGS="-O2 -g -pthread -I$MERGED_SYSROOT/include -I$MERGED_SYSROOT/include/wasm32-wasi"
WASM_LDFLAGS="-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base -L$MERGED_SYSROOT/lib/wasm32-wasi -L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

# Start from the native config.sh and override for WASI
cp "$NATIVE_BUILD_DIR/config.sh.native" config.sh

# Apply WASI overrides using sed
sed -i \
  -e "s|^cc=.*|cc='$CC_WASM'|" \
  -e "s|^ld=.*|ld='$CC_WASM'|" \
  -e "s|^ar=.*|ar='$AR'|" \
  -e "s|^ranlib=.*|ranlib='$RANLIB'|" \
  -e "s|^ccflags=.*|ccflags='$WASM_CFLAGS'|" \
  -e "s|^optimize=.*|optimize='-O2 -g'|" \
  -e "s|^ldflags=.*|ldflags='$WASM_LDFLAGS'|" \
  -e "s|^lddlflags=.*|lddlflags=''|" \
  -e "s|^ccdlflags=.*|ccdlflags=''|" \
  -e "s|^so=.*|so='wasm'|" \
  -e "s|^dlext=.*|dlext='wasm'|" \
  -e "s|^archname=.*|archname='wasm32-wasi'|" \
  -e "s|^myarchname=.*|myarchname='wasm32-wasi'|" \
  -e "s|^osname=.*|osname='wasi'|" \
  -e "s|^osvers=.*|osvers='0'|" \
  -e "s|^d_dlopen=.*|d_dlopen='undef'|" \
  -e "s|^d_fork=.*|d_fork='undef'|" \
  -e "s|^d_vfork=.*|d_vfork='undef'|" \
  -e "s|^usedl=.*|usedl='undef'|" \
  -e "s|^usethreads=.*|usethreads='undef'|" \
  -e "s|^useithreads=.*|useithreads='undef'|" \
  -e "s|^usemultiplicity=.*|usemultiplicity='undef'|" \
  -e "s|^useshrplib=.*|useshrplib='false'|" \
  -e "s|^ptrsize=.*|ptrsize='4'|" \
  -e "s|^longsize=.*|longsize='4'|" \
  -e "s|^sizesize=.*|sizesize='4'|" \
  -e "s|^ivsize=.*|ivsize='4'|" \
  -e "s|^uvsize=.*|uvsize='4'|" \
  -e "s|^nvsize=.*|nvsize='8'|" \
  -e "s|^lseeksize=.*|lseeksize='8'|" \
  -e "s|^alignbytes=.*|alignbytes='8'|" \
  -e "s|^byteorder=.*|byteorder='1234'|" \
  -e "s|^d_sigaction=.*|d_sigaction='undef'|" \
  -e "s|^d_sigprocmask=.*|d_sigprocmask='undef'|" \
  -e "s|^d_setitimer=.*|d_setitimer='undef'|" \
  -e "s|^d_getitimer=.*|d_getitimer='undef'|" \
  -e "s|^d_alarm=.*|d_alarm='undef'|" \
  -e "s|^d_semget=.*|d_semget='undef'|" \
  -e "s|^d_semctl=.*|d_semctl='undef'|" \
  -e "s|^d_semop=.*|d_semop='undef'|" \
  -e "s|^d_msg=.*|d_msg='undef'|" \
  -e "s|^d_shm=.*|d_shm='undef'|" \
  -e "s|^d_socket=.*|d_socket='define'|" \
  -e "s|^d_select=.*|d_select='define'|" \
  -e "s|^d_poll=.*|d_poll='define'|" \
  -e "s|^exe_ext=.*|exe_ext=''|" \
  -e "s|^_exe=.*|_exe=''|" \
  -e "s|^libs=.*|libs='-lpthread -lm'|" \
  -e "s|^perllibs=.*|perllibs='-lpthread -lm'|" \
  -e "s|^d_crypt=.*|d_crypt='undef'|" \
  -e "s|^cryptlib=.*|cryptlib=''|" \
  -e "s|^d_suidsafe=.*|d_suidsafe='undef'|" \
  -e "s|^d_dosuid=.*|d_dosuid='undef'|" \
  -e "s|^d_spawn=.*|d_spawn='undef'|" \
  -e "s|^d_aspawn=.*|d_aspawn='undef'|" \
  config.sh

# Regenerate all config-dependent files from config.sh
echo "[perl] [wasm] regenerating config.h, Makefile, and support scripts..."
sh config_h.SH
sh cflags.SH
sh makedepend.SH
sh makedepend_file.SH
sh Makefile.SH

# Prevent make from rebuilding generate_uudmap with the wasm compiler.
# The dependency chain is: generate_uudmap.o → generate_uudmap → bitcount.h
# We need ALL three to exist with headers newest so make skips the entire chain.
echo "[perl] [wasm] placing native generate_uudmap and generated headers..."
cp "$NATIVE_BUILD_DIR/generate_uudmap" ./generate_uudmap
chmod +x ./generate_uudmap
# Create a dummy .o so make doesn't recompile it (which would trigger relink)
touch generate_uudmap.o
for f in bitcount.h mg_data.h uudmap.h; do
  if [[ -f "$NATIVE_BUILD_DIR/$f" ]]; then
    cp "$NATIVE_BUILD_DIR/$f" .
  fi
done
# Ensure timestamps: .o oldest, then binary, then headers newest
touch -t 202001010000 generate_uudmap.o
touch -t 202001010001 generate_uudmap
touch bitcount.h mg_data.h uudmap.h

# --- Build perl for WASM ---------------------------------------------------

echo "[perl] [wasm] building perl..."
make -j"$JOBS" \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LDFLAGS="$WASM_LDFLAGS" \
  || {
    echo "[perl] WARNING: build had errors (best-effort, continuing)."
}

PERL_BIN="$PERL_ROOT/perl"
if [[ ! -f "$PERL_BIN" && -f "$PERL_ROOT/perl.wasm" ]]; then
  PERL_BIN="$PERL_ROOT/perl.wasm"
fi

if [[ ! -f "$PERL_BIN" ]]; then
  echo "[perl] ERROR: perl binary not produced." >&2
  exit 1
fi

PERL_WASM="$SCRIPT_DIR/perl.wasm"
PERL_OPT_WASM="$SCRIPT_DIR/perl.opt.wasm"
PERL_OPT_CWASM="$SCRIPT_DIR/perl.opt.cwasm"

cp "$PERL_BIN" "$PERL_WASM"

###############################################################################
# wasm-opt + precompile
###############################################################################

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
