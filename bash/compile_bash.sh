#!/usr/bin/env bash
set -euo pipefail

# This script builds bash as a wasm32-wasi binary using the lind-wasm-apps
# infrastructure:
#   - toolchain is picked by the top-level Makefile (build/.toolchain.env)
#   - sysroot comes from build/sysroot_merged
#   - output is staged into build/bin/bash/wasm32-wasi/
#
# It is intended to be called from the top-level Makefile via:
#   make bash

# ---------------------------------------------------------------------------
# Paths / shared state from lind-wasm-apps
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
APPS_LIB_DIR="$APPS_BUILD/lib"
APPS_BIN_DIR="$APPS_BUILD/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

BASH_SRC="$SCRIPT_DIR"
OUT_DIR="$APPS_BIN_DIR/bash/wasm32-wasi"

if [[ ! -r "$TOOL_ENV" ]]; then
  echo "[bash] ERROR: $TOOL_ENV not found. Run 'make preflight' from lind-wasm-apps root." >&2
  exit 1
fi

# Load CLANG/AR/RANLIB chosen by preflight
# shellcheck disable=SC1090
. "$TOOL_ENV"

: "${CLANG:?CLANG not set in $TOOL_ENV}"
: "${AR:?AR not set in $TOOL_ENV}"

# LIND_WASM_ROOT is only needed for wasm-opt / wasmtime; fall back to ~/lind-wasm
LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
WASM_OPT="${WASM_OPT:-"$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt"}"
WASMTIME="${WASMTIME:-"$LIND_WASM_ROOT/src/wasmtime/target/release/wasmtime"}"

mkdir -p "$OUT_DIR"

echo "[bash] APPS_ROOT      = $APPS_ROOT"
echo "[bash] APPS_BUILD     = $APPS_BUILD"
echo "[bash] MERGED_SYSROOT = $MERGED_SYSROOT"
echo "[bash] OUT_DIR        = $OUT_DIR"
echo "[bash] CLANG          = $CLANG"
echo "[bash] AR             = $AR"
echo "[bash] WASM_OPT       = $WASM_OPT"
echo "[bash] WASMTIME       = $WASMTIME"
echo

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[bash] ERROR: merged sysroot not found at $MERGED_SYSROOT (run 'make merge-sysroot' first)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# WASM compatibility header (already tracked in repo)
# ---------------------------------------------------------------------------
WASM_COMPAT_H="$BASH_SRC/wasm_compat.h"

if [[ ! -f "$WASM_COMPAT_H" ]]; then
  echo "[bash] ERROR: wasm_compat.h not found at $WASM_COMPAT_H" >&2
  echo "[bash]        (this file is expected to be tracked in the repo)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Toolchain flags for wasm32-wasi bash
# ---------------------------------------------------------------------------
CC_WASM="$CLANG -pthread --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT"
CFLAGS_WASM="-O2 -g -std=gnu89 -pthread -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1 -include $WASM_COMPAT_H"
LDFLAGS_WASM="-Wl,--import-memory,--export-memory,--max-memory=67108864,\
--export=__stack_pointer,--export=__stack_low \
-L$MERGED_SYSROOT/lib/wasm32-wasi -L$MERGED_SYSROOT/usr/lib/wasm32-wasi -L$APPS_LIB_DIR"

# liblmb_stubs.a comes from the top-level 'stubs' target; bash may need
# scheduler shims, so link it in.
LDLIBS_WASM="-llmb_stubs"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

echo "[bash] Using:"
echo "  CC      = $CC_WASM"
echo "  CFLAGS  = $CFLAGS_WASM"
echo "  LDFLAGS = $LDFLAGS_WASM"
echo "  AR      = $AR"
echo

# ---------------------------------------------------------------------------
# Ensure bash is configured (native-style configure)
# ---------------------------------------------------------------------------
pushd "$BASH_SRC" >/dev/null

if [[ ! -f Makefile ]]; then
  echo "[bash] No Makefile found; running configure for bash..."
  ./configure \
    --without-bash-malloc \
    --disable-nls \
    --disable-profiling
fi

# ---------------------------------------------------------------------------
# Build objects and libs with the WASM toolchain
#   (adapted from Robin's script, but using shared sysroot & toolchain)
# ---------------------------------------------------------------------------
echo "[bash] Cleaning previous wasm build..."
make clean || true

echo "[bash] Building top-level objects (WASM target)..."
make -j1 \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM $LDLIBS_WASM" \
  AR="$AR" \
  ARFLAGS="crs" \
  RANLIB="echo" \
  TERMCAP_LIB="" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  signames.o

echo "[bash] Building libraries in subdirs..."
for d in builtins lib/glob lib/sh lib/readline lib/tilde; do
  echo "[bash]   -> $d"
  make -j1 -C "$d" \
    V=1 \
    CC="$CC_WASM" \
    CFLAGS="$CFLAGS_WASM" \
    AR="$AR" \
    ARFLAGS="crs" \
    RANLIB="echo"
done

# Remove mktime.o from libsh to avoid clashes with libc
if [[ -f ./lib/sh/libsh.a ]]; then
  echo "[bash] Removing mktime.o from lib/sh/libsh.a ..."
  "$AR" d ./lib/sh/libsh.a mktime.o || true
fi

# ---------------------------------------------------------------------------
# Termcap stubs for readline
# ---------------------------------------------------------------------------
TPUTS_STUB_C="$BASH_SRC/tputs_stub.c"
TPUTS_STUB_O="$BASH_SRC/tputs_stub.o"

cat > "$TPUTS_STUB_C" << 'EOF'
/* Minimal termcap stubs for readline on WASI. */

int tputs(const char *str, int affcnt, int (*putc_fn)(int))
{
    (void)affcnt;
    if (!str || !putc_fn)
        return 0;
    const unsigned char *p = (const unsigned char *)str;
    while (*p)
        putc_fn(*p++);
    return 0;
}

char *tgoto(const char *cm, int destcol, int destline)
{
    (void)cm;
    (void)destcol;
    (void)destline;
    static char buf[1];
    buf[0] = '\0';
    return buf;
}

int tgetnum(const char *id)
{
    (void)id;
    return -1;
}

int tgetent(char *bp, const char *name)
{
    (void)bp;
    (void)name;
    return 0;
}

char *tgetstr(const char *id, char **area)
{
    (void)id;
    (void)area;
    return (char *)0;
}

int tgetflag(const char *id)
{
    (void)id;
    return 0;
}
EOF

echo "[bash] Compiling termcap stubs ..."
$CC_WASM $CFLAGS_WASM -c "$TPUTS_STUB_C" -o "$TPUTS_STUB_O"

# ---------------------------------------------------------------------------
# Locale stub to avoid __ctype_get_mb_cur_max traps
# ---------------------------------------------------------------------------
LOCALE_STUB_C="$BASH_SRC/locale_stub.c"
LOCALE_STUB_O="$BASH_SRC/locale_stub.o"

cat > "$LOCALE_STUB_C" << 'EOF'
/* Minimal locale stub for WASM. Avoids heavy locale logic. */

#include <stddef.h>

size_t __ctype_get_mb_cur_max(void)
{
    /* Treat all locales as single-byte for now. */
    return 1;
}
EOF

echo "[bash] Compiling locale stub ..."
$CC_WASM $CFLAGS_WASM -c "$LOCALE_STUB_C" -o "$LOCALE_STUB_O"

# ---------------------------------------------------------------------------
# Manual link of bash (WASM)
# ---------------------------------------------------------------------------
echo "[bash] Linking bash manually with clang..."
$CC_WASM \
  -L./builtins \
  -L./lib/readline \
  -L./lib/glob \
  -L./lib/tilde \
  -L./lib/sh \
  $LDFLAGS_WASM $LDLIBS_WASM \
  -o bash \
  "$LOCALE_STUB_O" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o syntax.o xmalloc.o \
  signames.o \
  "$TPUTS_STUB_O" \
  -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde

if [[ ! -f bash ]]; then
  echo "[bash] ERROR: bash binary not produced by manual link." >&2
  exit 1
fi

echo "[bash] raw wasm binary built:"
ls -lh bash
echo

# ---------------------------------------------------------------------------
# Optional: wasm-opt + wasmtime compile, staged under build/bin
# ---------------------------------------------------------------------------
WASM_FILE="$OUT_DIR/bash.wasm"
CWA_FILE="$OUT_DIR/bash.cwasm"

if [[ -x "$WASM_OPT" ]]; then
  echo "[bash] Running wasm-opt -> $WASM_FILE ..."
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      bash -o "$WASM_FILE"
else
  echo "[bash] WARNING: wasm-opt not found at $WASM_OPT; copying raw 'bash' to $WASM_FILE"
  cp bash "$WASM_FILE"
fi

if [[ -x "$WASMTIME" ]]; then
  echo "[bash] Running wasmtime compile -> $CWA_FILE ..."
  "$WASMTIME" compile "$WASM_FILE" -o "$CWA_FILE"
else
  echo "[bash] WARNING: wasmtime not found at $WASMTIME; skipping .cwasm compilation"
fi

echo
echo "[bash] Build complete. Output files:"
ls -lh "$OUT_DIR"

popd >/dev/null
