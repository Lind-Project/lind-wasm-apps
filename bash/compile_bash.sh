#!/usr/bin/env bash
set -euo pipefail

CLANG="/home/lind/lind-wasm/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"
LLVM_AR="$(dirname "$CLANG")/llvm-ar"
WASM_OPT="/home/lind/lind-wasm/tools/binaryen/bin/wasm-opt"
WASMTIME="/home/lind/lind-wasm/src/wasmtime/target/debug/wasmtime"

BASH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASH_ROOT"

SYSROOT="$BASH_ROOT/sysroot_overlay"
OUT_DIR="$BASH_ROOT/out_wasm"

GLIBC_SYSROOT="/home/lind/lind-wasm/src/glibc/sysroot"

mkdir -p "$OUT_DIR"

echo "BASH_ROOT     = $BASH_ROOT"
echo "SYSROOT       = $SYSROOT"
echo "GLIBC_SYSROOT = $GLIBC_SYSROOT"
echo "OUT_DIR       = $OUT_DIR"
echo

# 1) Prepare sysroot_overlay
if [ ! -d "$SYSROOT" ]; then
    echo "Creating sysroot_overlay from GLIBC_SYSROOT..."
    if [ ! -d "$GLIBC_SYSROOT" ]; then
        echo "Error: GLIBC_SYSROOT '$GLIBC_SYSROOT' does not exist."
        exit 1
    fi
    mkdir -p "$SYSROOT"
    cp -a "$GLIBC_SYSROOT/." "$SYSROOT/"
    echo "sysroot_overlay created."
    echo
fi

# 2) Check Makefile
if [ ! -f Makefile ]; then
    echo "Error: Makefile not found in $BASH_ROOT."
    echo "Run native configure first:"
    echo "  ./configure --without-bash-malloc --disable-nls --disable-profiling"
    exit 1
fi

# 3) WASI compatibility header
WASM_COMPAT_H="$BASH_ROOT/wasm_compat.h"

cat > "$WASM_COMPAT_H" << 'EOF'
#ifndef WASM_COMPAT_H
#define WASM_COMPAT_H

#ifdef __wasi__
#include <sys/stat.h>

/* Map old stat field names to WASI fields (seconds only). */
#ifndef st_atime
#define st_atime st_atim.tv_sec
#endif

#ifndef st_mtime
#define st_mtime st_mtim.tv_sec
#endif

#ifndef st_ctime
#define st_ctime st_ctim.tv_sec
#endif

#endif /* __wasi__ */

#endif /* WASM_COMPAT_H */
EOF

# 4) WASM build flags
CC_WASM="$CLANG -pthread --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
CFLAGS_WASM="-O2 -g -std=gnu89 -pthread -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1 -include $WASM_COMPAT_H"
LDFLAGS_WASM="-Wl,--import-memory,--export-memory,--max-memory=67108864,\
--export=__stack_pointer,--export=__stack_low"

echo "Using:"
echo "  CC      = $CC_WASM"
echo "  CFLAGS  = $CFLAGS_WASM"
echo "  LDFLAGS = $LDFLAGS_WASM"
echo "  AR      = $LLVM_AR"
echo

# 5) Build objects and libs with WASM toolchain
echo "Running make clean..."
make clean || true

echo "Building top-level objects (WASM target)..."
make -j1 \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$LLVM_AR" \
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

echo "Building libraries in subdirs..."
make -j1 -C builtins \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$LLVM_AR" \
  ARFLAGS="crs" \
  RANLIB="echo"

make -j1 -C lib/glob \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$LLVM_AR" \
  ARFLAGS="crs" \
  RANLIB="echo"

make -j1 -C lib/sh \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$LLVM_AR" \
  ARFLAGS="crs" \
  RANLIB="echo"

make -j1 -C lib/readline \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$LLVM_AR" \
  ARFLAGS="crs" \
  RANLIB="echo"

make -j1 -C lib/tilde \
  V=1 \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  AR="$LLVM_AR" \
  ARFLAGS="crs" \
  RANLIB="echo"

# 6) Remove mktime.o from libsh to avoid clash with libc
if [ -f ./lib/sh/libsh.a ]; then
    echo "Removing mktime.o from lib/sh/libsh.a ..."
    "$LLVM_AR" d ./lib/sh/libsh.a mktime.o || true
fi

# 7) Create termcap stubs for readline
TPUTS_STUB_C="$BASH_ROOT/tputs_stub.c"
TPUTS_STUB_O="$BASH_ROOT/tputs_stub.o"

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

echo "Compiling termcap stubs ..."
$CC_WASM $CFLAGS_WASM -c "$TPUTS_STUB_C" -o "$TPUTS_STUB_O"

# 8) Create locale stubs to avoid __ctype_get_mb_cur_max trap
LOCALE_STUB_C="$BASH_ROOT/locale_stub.c"
LOCALE_STUB_O="$BASH_ROOT/locale_stub.o"

cat > "$LOCALE_STUB_C" << 'EOF'
/* Minimal locale stub for WASM. Avoids heavy locale logic. */

#include <stddef.h>

size_t __ctype_get_mb_cur_max(void)
{
    /* Treat all locales as single-byte for now. */
    return 1;
}
EOF

echo "Compiling locale stubs ..."
$CC_WASM $CFLAGS_WASM -c "$LOCALE_STUB_C" -o "$LOCALE_STUB_O"

# 9) Manual link of bash (WASM)
echo "Linking bash manually with clang..."
$CC_WASM \
  -L./builtins \
  -L./lib/readline \
  -L./lib/readline \
  -L./lib/glob \
  -L./lib/tilde \
  -L./lib/sh \
  $LDFLAGS_WASM \
  -o bash \
  "$LOCALE_STUB_O" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o \
  dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o \
  expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o \
  trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o \
  alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o \
  bashhist.o bashline.o siglist.o list.o stringlib.o locale.o \
  findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  signames.o \
  "$TPUTS_STUB_O" \
  -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde

if [ ! -f bash ]; then
    echo "Error: bash binary not produced by manual link."
    exit 1
fi

echo
echo "bash built:"
ls -lh bash
echo

# 10) wasm-opt and wasmtime compile
WASM_FILE="$OUT_DIR/bash.wasm"
CWA_FILE="$OUT_DIR/bash.cwasm"

echo "Running wasm-opt -> $WASM_FILE ..."
"$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
    bash -o "$WASM_FILE"

echo "Running wasmtime compile -> $CWA_FILE ..."
"$WASMTIME" compile "$WASM_FILE" -o "$CWA_FILE"

echo
echo "Build complete. Output files:"
ls -lh "$OUT_DIR"
