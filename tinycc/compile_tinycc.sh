#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# tinycc WASI build helper for lind-wasm-apps
#
# Produces a wasm tinycc compiler that can compile C programs to 32-bit ELF
# binaries (i386 target).
#
# libtcc1.a is a static archive used by tcc at compile time to produce correct
# native binaries. Since the target is i386, libtcc1.a is compiled as an i386
# object using the host gcc.
#
# The required header files and i386 runtime files (libc.so, ld.so,
# libc_nonshared.a, crt1.o) are also staged to build/ for later installation
# into lindfs.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/tinycc"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm-apps is parallel to lind-wasm)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/../lind-wasm" && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[tinycc] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"

# Sanity
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[tinycc] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# ----------------------------------------------------------------------
# 2) WASM toolchain flags
# ----------------------------------------------------------------------
# tinycc uses -O0 because the configure/build system relies on specific code
# generation behavior that breaks with optimization (e.g. inline assembly
# patterns for the i386 code generator).
CFLAGS_WASM="--target=wasm32-wasi -g -O0 --sysroot=$MERGED_SYSROOT -pthread -matomics -mbulk-memory -fno-pie -fvisibility=default -fno-builtin"

if [[ -z "${LIND_ASYNCIFY_SETJMP:-}" ]]; then
  CFLAGS_WASM="$CFLAGS_WASM -fwasm-exceptions -mllvm -wasm-enable-sjlj"
fi

LDFLAGS_WASM="--target=wasm32-wasi -g -O0 --sysroot=$MERGED_SYSROOT -static -Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"

echo "[tinycc] using CLANG       = $CLANG"
echo "[tinycc] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[tinycc] merged sysroot    = $MERGED_SYSROOT"
echo "[tinycc] stage dir         = $STAGE_DIR"
echo

# ----------------------------------------------------------------------
# 3) Configure and build tcc
# ----------------------------------------------------------------------
pushd "$SCRIPT_DIR" >/dev/null

./configure \
  --cpu=i386 \
  --cc="$CLANG" \
  --extra-cflags="$CFLAGS_WASM" \
  --extra-ldflags="$LDFLAGS_WASM" \
  --enable-static --enable-cross --extra-libs=""

echo "CONFIG_ldl=no" >> config.mak

make tcc

if [[ ! -f "tcc" ]]; then
  echo "[tinycc] ERROR: tcc binary was not generated!"
  exit 1
fi

mv tcc tcc.wasm

# ----------------------------------------------------------------------
# 4) Build libtcc1.a (i386 native — used by tcc to produce native binaries)
# ----------------------------------------------------------------------
gcc -m32 -O2 -DTCC_TARGET_I386 -c lib/libtcc1.c -o libtcc1.o
ar rcs libtcc1.a libtcc1.o

# ----------------------------------------------------------------------
# 5) wasm-opt (asyncify + optimization)
# ----------------------------------------------------------------------
TCC_WASM="$SCRIPT_DIR/tcc.wasm"
TCC_OPT_WASM="$SCRIPT_DIR/tcc.opt.wasm"

if [[ -x "$WASM_OPT" ]]; then
  echo "[tinycc] running wasm-opt (asyncify + optimization)..."
  "$WASM_OPT" \
    --epoch-injection \
    --asyncify \
    --debuginfo \
    -O2 \
    "$TCC_WASM" \
    -o "$TCC_OPT_WASM"
else
  echo "[tinycc] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
  exit 1
fi

if [[ ! -f "$TCC_OPT_WASM" ]]; then
  echo "[tinycc] ERROR: Failed to generate $TCC_OPT_WASM" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 6) cwasm generation via lind-boot --precompile
# ----------------------------------------------------------------------
if [[ -x "$LIND_BOOT" ]]; then
  echo "[tinycc] generating cwasm via lind-boot --precompile..."
  if "$LIND_BOOT" --precompile "$TCC_OPT_WASM"; then

    TCC_OPT_CWASM="$SCRIPT_DIR/tcc.opt.cwasm"

    if [[ -f "$TCC_OPT_CWASM" ]]; then
      mkdir -p "$STAGE_DIR/bin"
      cp "$TCC_OPT_CWASM" "$STAGE_DIR/bin/tcc"
      echo "[tinycc] tinycc staged as $STAGE_DIR/bin/tcc"
    else
      echo "[tinycc] ERROR: No .cwasm binary generated." >&2
      exit 1
    fi
  else
    echo "[tinycc] ERROR: lind-boot --precompile failed." >&2
    exit 1
  fi
else
  echo "[tinycc] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# 7) Stage supporting files (libtcc1, headers, i386 runtime)
# ----------------------------------------------------------------------
mkdir -p "$STAGE_DIR/usr/local/lib/tcc"
cp libtcc1.a "$STAGE_DIR/usr/local/lib/tcc/"

# Headers required to compile C programs using tinycc
tar -xvzf tcc_headers.tar.gz
rsync -a "${SCRIPT_DIR}/tcc_headers/" "$STAGE_DIR/"

# i386 runtime files: tcc needs 32-bit libc.so, ld.so, libc_nonshared.a and
# crt object files. These are staged into the build dir and later copied to
# lindfs at 'make install' time.
mkdir -p "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/crt*.o "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc.so* "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/ld-linux.so.2 "$STAGE_DIR/usr/lib/i386-linux-gnu/"
cp /usr/i686-linux-gnu/lib/libc_nonshared.a "$STAGE_DIR/usr/lib/i386-linux-gnu/"

# Rewrite absolute paths in libc.so linker script so tcc can locate these
# files relative to lindfs
sed -i 's|[^ ]*/libc\.so\.6|libc.so.6|g; s|[^ ]*/libc_nonshared\.a|libc_nonshared.a|g; s|[^ ]*/ld-linux\.so\.2|ld-linux.so.2|g' "$STAGE_DIR/usr/lib/i386-linux-gnu/libc.so"

# ----------------------------------------------------------------------
# 8) Host 32-bit dynamic linker setup
# ----------------------------------------------------------------------
# Dynamically linked executables produced by tcc expect the i386 linker at
# /lib/ld-linux.so.2. This is a host-level prerequisite — print instructions
# rather than modifying the host system with sudo during a build.
if [[ ! -e /lib/ld-linux.so.2 ]]; then
  echo ""
  echo "[tinycc] WARNING: /lib/ld-linux.so.2 not found."
  echo "  To run dynamically-linked i386 binaries produced by tcc, run:"
  echo "    sudo ln -s /usr/i686-linux-gnu/lib/ld-linux.so.2 /lib/ld-linux.so.2"
  echo "    echo '/usr/i686-linux-gnu/lib' | sudo tee /etc/ld.so.conf.d/i686-cross.conf"
  echo "    sudo ldconfig"
  echo ""
fi

popd >/dev/null

echo
echo "[tinycc] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR/bin" || true
