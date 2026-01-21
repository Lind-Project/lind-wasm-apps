#!/usr/bin/env bash
set -euo pipefail

echo "========== coreutils → WASM build (with shims and WASI hacks) =========="

APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIND_ROOT="$(cd "$APP_ROOT/../.." && pwd)"

GLIBC_SYSROOT="$LIND_ROOT/src/glibc/sysroot"
SYSROOT="$APP_ROOT/sysroot_overlay"
BUILD_DIR="$APP_ROOT/build_wasm"
OUT_DIR="$APP_ROOT/out_wasm"

CLANG="$LIND_ROOT/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/clang"
LLVM_RANLIB="$LIND_ROOT/clang+llvm-18.1.8-x86_64-linux-gnu-ubuntu-18.04/bin/llvm-ranlib"
LLVM_BIN_DIR="$(dirname "$CLANG")"
LLVM_AR="$LLVM_BIN_DIR/llvm-ar"

HOST_TRIPLE="riscv64-unknown-linux-gnu"
BUILD_TRIPLE="x86_64-pc-linux-gnu"

echo "[STEP 0] Write stdio shim to lib/wasm_stdio_shim.c ..."

cat > "$APP_ROOT/lib/wasm_stdio_shim.c" <<'EOF'
#include <stdio.h>
#include <errno.h>
#include <limits.h>
#include <sys/types.h>

size_t freadahead (FILE *fp) {
    (void) fp;
    return 0;
}

const char *freadptr (FILE *fp, size_t *sizep) {
    (void) fp;
    if (sizep) *sizep = 0;
    return NULL;
}

int freadseek (FILE *fp, size_t offset) {
    (void) fp;
    (void) offset;
    errno = ESPIPE;
    return -1;
}

void fseterr (FILE *fp) {
    (void) fp;
}

int fseeko (FILE *fp, off_t offset, int whence) {
    if (offset > (off_t)LONG_MAX || offset < (off_t)LONG_MIN) {
        errno = EOVERFLOW;
        return -1;
    }
    return fseek(fp, (long) offset, whence);
}

off_t ftello (FILE *fp) {
    long pos = ftell(fp);
    if (pos < 0)
        return (off_t) -1;
    return (off_t) pos;
}
EOF

echo "[STEP 0a] Write strtod_l/strtold_l shim to lib/wasm_strtod_shim.c ..."

cat > "$APP_ROOT/lib/wasm_strtod_shim.c" <<'EOF'
#include <stdlib.h>

double
strtod_l (const char *nptr, char **endptr, void *loc)
{
    (void) loc;
    return strtod (nptr, endptr);
}

long double
strtold_l (const char *nptr, char **endptr, void *loc)
{
    (void) loc;
    return strtold (nptr, endptr);
}
EOF

echo "[STEP 0b] Write extra shims to lib/wasm_extra_shim.c ..."

cat > "$APP_ROOT/lib/wasm_extra_shim.c" <<'EOF'
#include <stdlib.h>
#include <stddef.h>
#include <wchar.h>
#include <utmp.h>
#include <sys/time.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>

wchar_t *
wmempcpy (wchar_t *dst, const wchar_t *src, size_t n)
{
    return wmemcpy (dst, src, n) + n;
}

void *
rpl_calloc (size_t n, size_t size)
{
    return calloc (n, size);
}

const char *
rpl_gai_strerror (int err)
{
    (void) err;
    return "gai_strerror is not available on this WASI platform";
}

int
utmpxname (const char *file)
{
    return utmpname (file);
}

int
futimesat (int dirfd, const char *path, const struct timeval tv[2])
{
    (void) dirfd;
    (void) path;
    (void) tv;
    errno = ENOSYS;
    return -1;
}

int
euidaccess (const char *file, int mode)
{
    return access (file, mode);
}
EOF

echo "[STEP 0c] Drop hard #error from gnulib stdio sources ..."

for f in freadahead.c freadptr.c freadseek.c fseterr.c fseeko.c; do
  src="$APP_ROOT/lib/$f"
  if [ -f "$src" ] && grep -q "Please port gnulib" "$src"; then
    echo "  removing #error in $src"
    sed -i '/Please port gnulib/d' "$src"
  fi
done

echo "[STEP 0d] Patch unlinkat.c to include <stdlib.h> ..."

if [ -f "$APP_ROOT/lib/unlinkat.c" ]; then
  if ! grep -q 'stdlib.h' "$APP_ROOT/lib/unlinkat.c"; then
    sed -i '1i #include <stdlib.h>' "$APP_ROOT/lib/unlinkat.c"
  fi
fi

echo "[STEP 0e] Add WASI stat compatibility macros into utimecmp.c ..."

if [ -f "$APP_ROOT/lib/utimecmp.c" ]; then
  if ! grep -q 'WASI_STAT_COMPAT' "$APP_ROOT/lib/utimecmp.c"; then
    sed -i '1i \
#define WASI_STAT_COMPAT 1\
#define st_mtime st_mtim.tv_sec\
#define st_atime st_atim.tv_sec\
#define st_ctime st_ctim.tv_sec\
' "$APP_ROOT/lib/utimecmp.c"
  fi
fi

echo "[STEP 0f] Declare strtod_l/strtold_l prototypes in c-strtod.c ..."

if [ -f "$APP_ROOT/lib/c-strtod.c" ]; then
  if ! grep -q 'WASI_STRTOD_L_COMPAT' "$APP_ROOT/lib/c-strtod.c"; then
    sed -i '1i \
#define WASI_STRTOD_L_COMPAT 1\
double strtod_l (const char *, char **, void *);\
long double strtold_l (const char *, char **, void *);\
' "$APP_ROOT/lib/c-strtod.c"
  fi
fi

echo "[STEP 0g] Patch atexit.c to cast on_exit callback type ..."

if [ -f "$APP_ROOT/lib/atexit.c" ]; then
  if grep -q 'on_exit (f, 0);' "$APP_ROOT/lib/atexit.c"; then
    sed -i 's/on_exit (f, 0);/on_exit ((void (*)(int, void *)) f, 0);/' "$APP_ROOT/lib/atexit.c"
  fi
fi

echo "[STEP 0h] Declare wmempcpy prototype in fnmatch.c ..."

if [ -f "$APP_ROOT/lib/fnmatch.c" ]; then
  if ! grep -q 'WASI_WMEMPCPY_COMPAT' "$APP_ROOT/lib/fnmatch.c"; then
    sed -i '1i \
#define WASI_WMEMPCPY_COMPAT 1\
#include <wchar.h>\
wchar_t *wmempcpy (wchar_t *, const wchar_t *, size_t);\
' "$APP_ROOT/lib/fnmatch.c"
  fi
fi

echo "[STEP 0i] Declare rpl_calloc prototype in hash.c ..."

if [ -f "$APP_ROOT/lib/hash.c" ]; then
  if ! grep -q 'WASI_RPL_CALLOC_COMPAT' "$APP_ROOT/lib/hash.c"; then
    sed -i '1i \
#define WASI_RPL_CALLOC_COMPAT 1\
#include <stddef.h>\
void *rpl_calloc (size_t, size_t);\
' "$APP_ROOT/lib/hash.c"
  fi
fi

echo "[STEP 0j] Declare rpl_calloc prototype in regex_internal.c ..."

if [ -f "$APP_ROOT/lib/regex_internal.c" ]; then
  if ! grep -q 'WASI_RPL_CALLOC_REGEX_COMPAT' "$APP_ROOT/lib/regex_internal.c"; then
    sed -i '1i \
#define WASI_RPL_CALLOC_REGEX_COMPAT 1\
#include <stddef.h>\
void *rpl_calloc (size_t, size_t);\
' "$APP_ROOT/lib/regex_internal.c"
  fi
fi

echo "[STEP 0k] Declare rpl_calloc prototype in xmalloc.c ..."

if [ -f "$APP_ROOT/lib/xmalloc.c" ]; then
  if ! grep -q 'WASI_RPL_CALLOC_XMALLOC_COMPAT' "$APP_ROOT/lib/xmalloc.c"; then
    sed -i '1i \
#define WASI_RPL_CALLOC_XMALLOC_COMPAT 1\
#include <stddef.h>\
void *rpl_calloc (size_t, size_t);\
' "$APP_ROOT/lib/xmalloc.c"
  fi
fi

echo "[STEP 0l] Replace gai_strerror.c with stub ..."

if [ -f "$APP_ROOT/lib/gai_strerror.c" ]; then
  cat > "$APP_ROOT/lib/gai_strerror.c" <<'EOF'
const char *
rpl_gai_strerror (int err)
{
    (void) err;
    return "gai_strerror is not supported on this WASI build";
}
EOF
fi

echo "[STEP 0m] Declare utmpxname prototype in readutmp.c ..."

if [ -f "$APP_ROOT/lib/readutmp.c" ]; then
  if ! grep -q 'WASI_UTMPXNAME_COMPAT' "$APP_ROOT/lib/readutmp.c"; then
    sed -i '1i \
#define WASI_UTMPXNAME_COMPAT 1\
int utmpxname (const char *);\
' "$APP_ROOT/lib/readutmp.c"
  fi
fi

echo "[STEP 0n] Declare futimesat prototype in utimens.c ..."

if [ -f "$APP_ROOT/lib/utimens.c" ]; then
  if ! grep -q 'WASI_FUTIMESAT_COMPAT' "$APP_ROOT/lib/utimens.c"; then
    sed -i '1i \
#define WASI_FUTIMESAT_COMPAT 1\
#include <sys/time.h>\
int futimesat (int dirfd, const char *path, const struct timeval tv[2]);\
' "$APP_ROOT/lib/utimens.c"
  fi
fi

echo "[STEP 0o] Map st_atime in pinky/who ..."

for f in "$APP_ROOT/src/pinky.c" "$APP_ROOT/src/who.c"; do
  if [ -f "$f" ] && ! grep -q 'WASI_STAT_ATIME_SRC' "$f"; then
    sed -i '1i \
#define WASI_STAT_ATIME_SRC 1\
#define st_atime st_atim.tv_sec\
' "$f"
  fi
done

echo "[STEP 0p] Declare euidaccess prototype in test.c/copy.c/remove.c ..."

for f in "$APP_ROOT/src/test.c" "$APP_ROOT/src/copy.c" "$APP_ROOT/src/remove.c"; do
  if [ -f "$f" ] && ! grep -q 'WASI_EUIDACCESS' "$f"; then
    sed -i '1i \
int euidaccess (const char *file, int mode);\
' "$f"
  fi
done

echo "[STEP 0q] Fix argv-iter.h: drop _GL_ARG_NONNULL and add missing semicolons ..."

if [ -f "$APP_ROOT/lib/argv-iter.h" ]; then
  sed -i '/_GL_ARG_NONNULL/d' "$APP_ROOT/lib/argv-iter.h"

  sed -i 's/^\(struct argv_iterator \*argv_iter_init_argv (char \*\*argv)\)$/\1;/' \
    "$APP_ROOT/lib/argv-iter.h"
  sed -i 's/^\(struct argv_iterator \*argv_iter_init_stream (FILE \*fp)\)$/\1;/' \
    "$APP_ROOT/lib/argv-iter.h"
  sed -i 's/^\(char \*argv_iter (struct argv_iterator \*, enum argv_iter_err \*)\)$/\1;/' \
    "$APP_ROOT/lib/argv-iter.h"
  sed -i 's/^\(size_t argv_iter_n_args (struct argv_iterator const \*)\)$/\1;/' \
    "$APP_ROOT/lib/argv-iter.h"
  sed -i 's/^\(void argv_iter_free (struct argv_iterator \*)\)$/\1;/' \
    "$APP_ROOT/lib/argv-iter.h"
fi

echo "[STEP 0r] Map st_*time in stat.c ..."

if [ -f "$APP_ROOT/src/stat.c" ]; then
  if ! grep -q 'WASI_STAT_TIME_STAT' "$APP_ROOT/src/stat.c"; then
    sed -i '1i \
#define WASI_STAT_TIME_STAT 1\
#define st_atime st_atim.tv_sec\
#define st_mtime st_mtim.tv_sec\
#define st_ctime st_ctim.tv_sec\
' "$APP_ROOT/src/stat.c"
  fi
fi

echo "[STEP 0s] Patch localcharset.c to remove configmake.h and define LIBDIR ..."

if [ -f "$APP_ROOT/lib/localcharset.c" ]; then
  if ! grep -q 'WASI_LOCALCHARSET_LIBDIR' "$APP_ROOT/lib/localcharset.c"; then
    sed -i '/configmake.h/d' "$APP_ROOT/lib/localcharset.c"
    sed -i '1i \
#define WASI_LOCALCHARSET_LIBDIR 1\
#ifndef LIBDIR\
#define LIBDIR "/opt/coreutils-wasm/lib"\
#endif\
' "$APP_ROOT/lib/localcharset.c"
  fi
fi

echo "[STEP 0t] Patch mbchar.h to declare wcwidth ..."

if [ -f "$APP_ROOT/lib/mbchar.h" ]; then
  if ! grep -q 'WASI_MBCHAR_WCWIDTH' "$APP_ROOT/lib/mbchar.h"; then
    sed -i '1i \
#define WASI_MBCHAR_WCWIDTH 1\
#include <wchar.h>\
int wcwidth (wchar_t);\
' "$APP_ROOT/lib/mbchar.h"
  fi
fi

echo "[STEP 0u] Patch mbsalign.c to declare wcwidth ..."

if [ -f "$APP_ROOT/lib/mbsalign.c" ]; then
  if ! grep -q 'WASI_MBSALIGN_WCWIDTH' "$APP_ROOT/lib/mbsalign.c"; then
    sed -i '1i \
#define WASI_MBSALIGN_WCWIDTH 1\
#include <wchar.h>\
int wcwidth (wchar_t);\
' "$APP_ROOT/lib/mbsalign.c"
  fi
fi

echo "[STEP 0v] Patch mbsstr.c to declare mbslen ..."

if [ -f "$APP_ROOT/lib/mbsstr.c" ]; then
  if ! grep -q 'WASI_MBSSTR_MBSLEN' "$APP_ROOT/lib/mbsstr.c"; then
    sed -i '1i \
#define WASI_MBSSTR_MBSLEN 1\
#include <wchar.h>\
size_t mbslen (const char *);\
' "$APP_ROOT/lib/mbsstr.c"
  fi
fi

echo "[STEP 0w] Patch mbswidth.c to declare wcwidth ..."

if [ -f "$APP_ROOT/lib/mbswidth.c" ]; then
  if ! grep -q 'WASI_MBSWIDTH_WCWIDTH' "$APP_ROOT/lib/mbswidth.c"; then
    sed -i '1i \
#define WASI_MBSWIDTH_WCWIDTH 1\
#include <wchar.h>\
int wcwidth (wchar_t);\
' "$APP_ROOT/lib/mbswidth.c"
  fi
fi

echo "[STEP 0x] Patch propername.c to declare mbsstr ..."

if [ -f "$APP_ROOT/lib/propername.c" ]; then
  if ! grep -q 'WASI_PROPERNAME_MBSSTR' "$APP_ROOT/lib/propername.c"; then
    sed -i '1i \
#define WASI_PROPERNAME_MBSSTR 1\
char *mbsstr (const char *, const char *);\
' "$APP_ROOT/lib/propername.c"
  fi
fi

echo "[STEP 0y] Patch unistr.h to drop unused-parameter.h and define _GL_UNUSED_PARAMETER ..."

if [ -f "$APP_ROOT/lib/unistr.h" ]; then
  if ! grep -q 'WASI_UNISTR_UNUSED_PARAMETER' "$APP_ROOT/lib/unistr.h"; then
    sed -i 's/#include "unused-parameter.h"//g' "$APP_ROOT/lib/unistr.h"
    sed -i '1i \
#define WASI_UNISTR_UNUSED_PARAMETER 1\
#define _GL_UNUSED_PARAMETER\
' "$APP_ROOT/lib/unistr.h"
  fi
fi

echo "[STEP 1] Patch lib/Makefile.am to include shim sources ..."

if ! grep -q "wasm_stdio_shim" "$APP_ROOT/lib/Makefile.am"; then
  echo "lib_SOURCES += wasm_stdio_shim.c" >> "$APP_ROOT/lib/Makefile.am"
fi
if ! grep -q "wasm_strtod_shim" "$APP_ROOT/lib/Makefile.am"; then
  echo "lib_SOURCES += wasm_strtod_shim.c" >> "$APP_ROOT/lib/Makefile.am"
fi
if ! grep -q "wasm_extra_shim" "$APP_ROOT/lib/Makefile.am"; then
  echo "lib_SOURCES += wasm_extra_shim.c" >> "$APP_ROOT/lib/Makefile.am"
fi

echo "[STEP 2] Prepare sysroot_overlay ..."
mkdir -p "$SYSROOT"
rsync -a "$GLIBC_SYSROOT"/ "$SYSROOT"/

echo "[STEP 3] Prepare build directory ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "[STEP 4] Set toolchain environment ..."

export CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
export AR="$LLVM_AR"
export RANLIB="$LLVM_RANLIB"
export CFLAGS="-O2 -g"

export CPPFLAGS="\
  -include stdlib.h \
  -D_IO_EOF_SEEN=0x10 \
  -D_IO_ERR_SEEN=0x20 \
  -D_IO_IN_BACKUP=0x100 \
  -DGNULIB_FREADAHEAD=0 \
  -DGNULIB_FREADPTR=0 \
  -DGNULIB_FREADSEEK=0 \
  -DGNULIB_FSETERR=0 \
  -DGNULIB_FSEEKO=0 \
"

export LDFLAGS=""

echo "[STEP 5] Run configure ..."

cd "$BUILD_DIR"

"$APP_ROOT/configure" \
  --host="$HOST_TRIPLE" \
  --build="$BUILD_TRIPLE" \
  --prefix=/opt/coreutils-wasm \
  --disable-nls \
  --without-selinux \
  ac_cv_func_freadahead=no \
  ac_cv_func_freadptr=no \
  ac_cv_func_freadseek=no \
  ac_cv_func_fseterr=no \
  ac_cv_func_fseeko=no

echo "[STEP 5b] Patch build lib/Makefile to drop gnulib stdio and strto* modules ..."

if [ -f "$BUILD_DIR/lib/Makefile" ]; then
  sed -i '
    s/\bfreadahead\.c\b//g;
    s/\bfreadptr\.c\b//g;
    s/\bfreadseek\.c\b//g;
    s/\bfseterr\.c\b//g;
    s/\bfseeko\.c\b//g;
    s/\bstrtol\.c\b//g;
    s/\bstrtoul\.c\b//g;
    s/[[:space:]]strtol\.\$(OBJEXT)//g;
    s/[[:space:]]strtoul\.\$(OBJEXT)//g;
  ' "$BUILD_DIR/lib/Makefile"
fi

echo "[STEP 6] Build libcoreutils first ..."
make -C lib libcoreutils.a

echo "[STEP 6a] Strip strtol.o/strtoul.o ..."
(
  cd lib
  "$LLVM_AR" d libcoreutils.a strtol.o strtoul.o || true
)

echo "[STEP 6b] Build rest of coreutils ..."
make -j"$(nproc)"

echo "[STEP 7] Install ..."
mkdir -p "$OUT_DIR"
make install DESTDIR="$OUT_DIR"

echo
echo "========== BUILD COMPLETE =========="
echo "Binaries installed to:"
echo "    $OUT_DIR/opt/coreutils-wasm/bin"
