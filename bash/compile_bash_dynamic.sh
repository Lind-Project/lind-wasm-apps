#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Bash WASM Dynamic/Shared build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Run a native (host) bash build to generate mkbuiltins/headers.
#   2. Patch builtins/Makefile to handle dynamic linking specifics.
#   3. Clean host objects but KEEP mkbuiltins.
#   4. Rebuild core bash objects with wasm32-wasi toolchain using -fPIC.
#   5. Rebuild libraries in subdirectories with -fPIC.
#   6. Provide WASI stubs (termcap, locale, getgroups).
#   7. Link bash.wasm as a Position Independent Executable (PIE) with 
#      dynamic exports (-Wl,-pie, -Wl,--export-dynamic, etc.).
###############################################################################

# --- basic paths -------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASH_ROOT="$APPS_ROOT/bash"

TOOL_ENV="$APPS_ROOT/build/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck source=/dev/null
  . "$TOOL_ENV"
fi

if [[ -z "${CLANG:-}" ]]; then
  echo "[bash] ERROR: CLANG is not set. Run 'make preflight' from lind-wasm-apps root."
  exit 1
fi

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/build/sysroot}"
MERGED_SYSROOT="${APPS_MERGED:-$APPS_ROOT/build/sysroot_merged}"
LINDFS_ROOT="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

BASH_OUT_DIR="$APPS_ROOT/build/bin/bash/wasm32-wasi"
mkdir -p "$BASH_OUT_DIR"

WASM_COMPAT_H="$BASH_ROOT/wasm_compat.h"

# --- sanity checks -----------------------------------------------------------

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[bash] ERROR: merged sysroot '$MERGED_SYSROOT' not found."
  exit 1
fi

if [[ ! -f "$WASM_COMPAT_H" ]]; then
  echo "[bash] ERROR: missing bash/wasm_compat.h"
  exit 1
fi

# --- WASM dynamic toolchain flags --------------------------------------------

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

# Added -fPIC for Position Independent Code
CFLAGS_WASM="-O2 -g -std=gnu89 -pthread -fPIC \
  -DHAVE_STRSIGNAL=1 -DHAVE_MKTIME=1 \
  -include $WASM_COMPAT_H \
  -I$MERGED_SYSROOT/include \
  -I$MERGED_SYSROOT/include/wasm32-wasi"

# Dynamic/PIE linker flags are added
LDFLAGS_WASM="-fPIC -Wl,-pie \
-Wl,--import-table \
-Wl,--import-memory \
-Wl,--export-memory \
-Wl,--max-memory=67108864 \
-Wl,--export=__stack_pointer \
-Wl,--export=__stack_low \
-Wl,--allow-undefined \
-Wl,--unresolved-symbols=import-dynamic \
-Wl,--export-dynamic \
-Wl,--experimental-pic \
-L$MERGED_SYSROOT/lib/wasm32-wasi \
-L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

echo "[bash] using CLANG       = $CLANG"
echo "[bash] building dynamically with -fPIC and -pie"
echo

pushd "$BASH_ROOT" >/dev/null

###############################################################################
# 1. Native (host) bash build for mkbuiltins
###############################################################################

echo "[bash] [host] cleaning any previous host build..."
make distclean >/dev/null 2>&1 || true

echo "[bash] [host] configuring (native, job control disabled)..."
./configure \
  --without-bash-malloc \
  --disable-nls \
  --disable-profiling \
  --disable-job-control

###############################################################################
# 2. Patch builtins/Makefile 
# Note: For dynamic builds, if dlopen is needed later by loadable builtins, 
# we keep -ldl stripped here just for the native host step, but will append it 
# manually during the final WASM link step.
###############################################################################

if [[ -f builtins/Makefile ]]; then
  if grep -q -- '-ldl' builtins/Makefile 2>/dev/null; then
    sed -i 's/-ldl//g' builtins/Makefile
  fi
fi

echo "[bash] [host] building full native bash (this may take a bit)..."
make -j"$JOBS"

if [[ ! -x builtins/mkbuiltins ]]; then
  echo "[bash] ERROR: host builtins/mkbuiltins was not produced."
  exit 1
fi

###############################################################################
# 3. Clean host-built objects/libs
###############################################################################

echo "[bash] [wasm] cleaning host-built core objects..."
rm -f shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o bashhist.o bashline.o siglist.o list.o stringlib.o locale.o findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o signames.o

find builtins -maxdepth 1 -type f -name '*.o' ! -name 'mkbuiltins.o' -delete || true
rm -f lib/glob/*.o lib/sh/*.o lib/readline/*.o lib/tilde/*.o || true

rm -f builtins/libbuiltins.a lib/glob/libglob.a lib/sh/libsh.a lib/readline/libreadline.a lib/readline/libhistory.a lib/tilde/libtilde.a

###############################################################################
# 4. WASM build: core objects
###############################################################################

echo "[bash] [wasm] building core objects dynamically with wasm32-wasi..."
make -j1 V=1 CC="$CC_WASM" CFLAGS="$CFLAGS_WASM" LDFLAGS="$LDFLAGS_WASM" AR="$AR" ARFLAGS="crs" RANLIB="echo" TERMCAP_LIB="" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o bashhist.o bashline.o siglist.o list.o stringlib.o locale.o findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o

###############################################################################
# 5. WASM build: libraries in subdirectories
###############################################################################

for libdir in builtins lib/glob lib/sh lib/tilde; do
  echo "[bash] [wasm] building $libdir library..."
  make -j1 -C "$libdir" V=1 CC="$CC_WASM" CFLAGS="$CFLAGS_WASM" AR="$AR" ARFLAGS="crs" RANLIB="echo"
done

echo "[bash] [wasm] building lib/readline/libreadline.a + libhistory.a..."
make -j1 -C lib/readline V=1 CC="$CC_WASM" CFLAGS="$CFLAGS_WASM" AR="$AR" ARFLAGS="crs" RANLIB="echo" libreadline.a libhistory.a

for archive in libreadline.a libhistory.a; do
  if [[ -f "./lib/readline/$archive" ]]; then
    "$AR" d "./lib/readline/$archive" xmalloc.o || true
  fi
done

###############################################################################
# 6. Termcap + locale + getgroups stubs (WASI compatibility)
###############################################################################

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

echo "[bash] [wasm] compiling termcap stubs dynamically..."
$CC_WASM $CFLAGS_WASM -c "$TPUTS_STUB_C" -o "$TPUTS_STUB_O"

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

echo "[bash] [wasm] compiling locale stubs dynamically..."
$CC_WASM $CFLAGS_WASM -c "$LOCALE_STUB_C" -o "$LOCALE_STUB_O"

GROUPS_STUB_C="$BASH_ROOT/getgroups_stub.c"
GROUPS_STUB_O="$BASH_ROOT/getgroups_stub.o"

cat > "$GROUPS_STUB_C" << 'EOF'
/* Minimal getgroups(2) stub for WASI. */

#include <sys/types.h>

int getgroups(int size, gid_t list[])
{
    (void)size;
    (void)list;
    return 0;
}
EOF

echo "[bash] [wasm] compiling getgroups stub dynamically..."
$CC_WASM $CFLAGS_WASM -c "$GROUPS_STUB_C" -o "$GROUPS_STUB_O"


###############################################################################
# 7. Link bash.wasm
###############################################################################

BASH_WASM="$BASH_OUT_DIR/bash.wasm"

# KEY CHANGE 3: Linked as PIE and appended -ldl to support dlopen if the sysroot has it.
echo "[bash] [wasm] dynamically linking bash → $BASH_WASM ..."
$CC_WASM \
  -L./builtins -L./lib/readline -L./lib/glob -L./lib/tilde -L./lib/sh \
  $LDFLAGS_WASM \
  -o "$BASH_WASM" \
  "$BASH_ROOT/locale_stub.o" \
  "$BASH_ROOT/getgroups_stub.o" \
  shell.o eval.o y.tab.o general.o make_cmd.o print_cmd.o dispose_cmd.o execute_cmd.o variables.o copy_cmd.o error.o expr.o flags.o nojobs.o subst.o hashcmd.o hashlib.o mailcheck.o trap.o input.o unwind_prot.o pathexp.o sig.o test.o version.o alias.o array.o arrayfunc.o assoc.o braces.o bracecomp.o bashhist.o bashline.o siglist.o list.o stringlib.o locale.o findcmd.o redir.o pcomplete.o pcomplib.o syntax.o xmalloc.o \
  "$BASH_ROOT/tputs_stub.o" \
  -lbuiltins -lglob -lsh -lreadline -lhistory -ltilde -ldl

if [[ ! -f "$BASH_WASM" ]]; then
  echo "[bash] ERROR: bash.wasm was not produced."
  exit 1
fi

###############################################################################
# 8 & 9. wasm-opt & cwasm compile
###############################################################################

if [[ -x "$WASM_OPT" ]]; then
  echo "[bash] running wasm-opt (best-effort)..."
  OPT_WASM="$BASH_OUT_DIR/bash.opt.wasm"
  "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 "$BASH_WASM" -o "$OPT_WASM"
  BASH_WASM="$OPT_WASM"
fi

if [[ -x "$LIND_BOOT" ]]; then
  if "$LIND_BOOT" --precompile "$BASH_WASM"; then
    OPT_CWASM="${BASH_WASM%.wasm}.cwasm"
    CLEAN_CWASM="${OPT_CWASM/.opt/}"
    [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]] && mv "$OPT_CWASM" "$CLEAN_CWASM"
  fi
fi

###############################################################################
# 10. Install to Lind Filesystem
###############################################################################

echo "[bash] installing into Lind filesystem at $LINDFS_ROOT..."

# Ensure the /bin directory exists in lindfs
mkdir -p "$LINDFS_ROOT/bin"

# Copy the final optimized/linked bash.wasm
cp "$BASH_WASM" "$LINDFS_ROOT/bin/bash"
echo "[bash] installed bash.wasm -> $LINDFS_ROOT/bin/bash"

# If a precompiled .cwasm was generated, install that too
if [[ -n "${CLEAN_CWASM:-}" && -f "$CLEAN_CWASM" ]]; then
  cp "$CLEAN_CWASM" "$LINDFS_ROOT/bin/bash.cwasm"
  echo "[bash] installed bash.cwasm -> $LINDFS_ROOT/bin/bash.cwasm"
fi


popd >/dev/null
echo "[bash] dynamic build complete. Outputs under: $BASH_OUT_DIR"
