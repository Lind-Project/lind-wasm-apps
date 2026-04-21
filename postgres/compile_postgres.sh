#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# PostgreSQL WASM build helper for lind-wasm-apps
#
# Two-pass build strategy (like bash):
#   Pass 1 (native):  ./configure + make generated-headers +
#                      make generated-parser-sources on the host to produce
#                      flex/bison .c/.h files and Perl-generated catalog/node
#                      headers.
#   Pass 2 (WASM):    Clean .o files, re-configure for wasm32-wasi with a
#                      config cache, then build src/backend (best-effort).
#
# Only the backend binary (postgres) is targeted; client tools (psql, pg_dump,
# etc.) are out of scope.  This is a best-effort port — link or build failures
# are tolerated where possible.
#
# Prerequisites:
#   - Run 'make preflight' and 'make merge-sysroot' first
#   - flex, bison, and Perl must be installed on the host for Pass 1
###############################################################################

# --- basic paths -------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PG_ROOT="$APPS_ROOT/postgres"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/bin/postgres/wasm32-wasi"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"

# --- dynamic linking mode ----------------------------------------------------
LIND_DYLINK="${LIND_DYLINK:-0}"

# --- load toolchain ----------------------------------------------------------

if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[postgres] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"

# --- sanity checks -----------------------------------------------------------

if [[ ! -d "$PG_ROOT/src/backend" ]]; then
  echo "[postgres] ERROR: PostgreSQL source not found at: $PG_ROOT" >&2
  exit 1
fi

if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[postgres] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

# --- wasm_compat header (committed in the repo) -----------------------------

WASM_COMPAT_H="$PG_ROOT/wasm_compat.h"
if [[ ! -f "$WASM_COMPAT_H" ]]; then
  echo "[postgres] ERROR: missing postgres/wasm_compat.h (it should be committed in the repo)." >&2
  exit 1
fi

# --- WASM toolchain flags ---------------------------------------------------

LLVM_BIN_DIR="$(dirname "$CLANG")"
NM="${NM:-"$LLVM_BIN_DIR/llvm-nm"}"

CC_WASM="$CLANG --target=wasm32-unknown-wasi --sysroot=$MERGED_SYSROOT -pthread"

# Base CFLAGS (dylink adds -fPIC below)
CFLAGS_WASM="-O2 -g -pthread \
  -include $WASM_COMPAT_H \
  -I$MERGED_SYSROOT/include \
  -I$MERGED_SYSROOT/include/wasm32-wasi \
  -DWAIT_USE_POLL"

# 256 MB max memory — PG allocates shared buffers even in single-user mode
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[postgres] Dynamic linking mode enabled (LIND_DYLINK=1)"

  # Add PIC for position-independent code
  CFLAGS_WASM="$CFLAGS_WASM -fPIC"

  # add-export-tool is used after wasm-opt to export relocation and stack symbols
  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[postgres] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  # Extra CRT objects required for dynamic PIE executables
  DYLINK_CRT_OBJS=(
    "$MERGED_SYSROOT/lib/wasm32-wasi/set_stack_pointer.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$MERGED_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[postgres] ERROR: required dylink CRT object '$obj' not found." >&2
      echo "[postgres] Hint: rebuild sysroot on the dylink branch (make sysroot in lind-wasm)." >&2
      exit 1
    fi
  done

  # Dylink LDFLAGS for actual build
  LDFLAGS_WASM="-nostartfiles \
    -Wl,-pie \
    -Wl,--import-table \
    -Wl,--import-memory \
    -Wl,--export-memory \
    -Wl,--shared-memory \
    -Wl,--max-memory=268435456 \
    -Wl,--allow-undefined \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,--export=__wasm_call_ctors \
    -Wl,--export-if-defined=__wasm_init_tls \
    -Wl,--export=__tls_base \
    -Wl,-z,stack-size=8388608 \
    -L$MERGED_SYSROOT/lib/wasm32-wasi \
    -L$MERGED_SYSROOT/usr/lib/wasm32-wasi \
    ${DYLINK_CRT_OBJS[*]}"

  # Static LDFLAGS for configure (correct feature detection)
  LDFLAGS_CONFIGURE="-Wl,--import-memory,--export-memory,\
--max-memory=268435456,--export=__stack_pointer,--export=__stack_low,-z,stack-size=8388608 \
-L$MERGED_SYSROOT/lib/wasm32-wasi \
-L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

else
  # Static LDFLAGS (original)
  LDFLAGS_WASM="-Wl,--import-memory,--export-memory,\
--max-memory=268435456,--export=__stack_pointer,--export=__stack_low,-z,stack-size=8388608 \
-L$MERGED_SYSROOT/lib/wasm32-wasi \
-L$MERGED_SYSROOT/usr/lib/wasm32-wasi"

  LDFLAGS_CONFIGURE="$LDFLAGS_WASM"
fi

echo "[postgres] using CLANG       = $CLANG"
echo "[postgres] using AR          = $AR"
echo "[postgres] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[postgres] merged sysroot    = $MERGED_SYSROOT"
echo "[postgres] stage dir         = $STAGE_DIR"
echo "[postgres] dylink mode       = $LIND_DYLINK"
echo

cd "$PG_ROOT"

###############################################################################
# Pass 1: Native build for generated headers and parser sources
###############################################################################

echo "[postgres] ============================================"
echo "[postgres] Pass 1: Native build (generated sources)"
echo "[postgres] ============================================"

echo "[postgres] [host] cleaning any previous build..."
make distclean >/dev/null 2>&1 || true

echo "[postgres] [host] configuring (native)..."
./configure \
  --without-readline \
  --without-icu \
  --without-zlib \
  --without-lz4 \
  --without-zstd \
  --without-llvm \
  --without-libcurl \
  --disable-nls \
  --disable-tap-tests \
  --disable-dtrace

echo "[postgres] [host] building generated headers..."
make -C src/backend generated-headers -j"$JOBS"

echo "[postgres] [host] building generated parser sources..."
make -C src/backend generated-parser-sources -j"$JOBS"

# Also build libpgport and libpgcommon natively — they're needed for the
# generated header infrastructure to complete
echo "[postgres] [host] building port/common libraries (native)..."
make -C src/port -j"$JOBS" || true
make -C src/common -j"$JOBS" || true

# Touch generated files to preserve timestamps across the clean
echo "[postgres] [host] preserving generated file timestamps..."
find src -name '*.c' -newer configure -print0 2>/dev/null | xargs -0 touch -r configure 2>/dev/null || true
find src -name '*.h' -newer configure -print0 2>/dev/null | xargs -0 touch -r configure 2>/dev/null || true

# Save a list of generated .c and .h files before cleaning
GENERATED_FILES=$(mktemp)
{
  # Parser-generated sources
  find src/backend/parser -name 'gram.c' -o -name 'gram.h' -o -name 'scan.c' 2>/dev/null
  find src/backend/bootstrap -name 'bootparse.c' -o -name 'bootparse.h' -o -name 'bootscanner.c' 2>/dev/null
  find src/backend/replication -name 'repl_gram.c' -o -name 'repl_gram.h' -o -name 'repl_scanner.c' \
       -o -name 'syncrep_gram.c' -o -name 'syncrep_gram.h' -o -name 'syncrep_scanner.c' 2>/dev/null
  find src/backend/utils/adt -name 'jsonpath_gram.c' -o -name 'jsonpath_gram.h' -o -name 'jsonpath_scan.c' 2>/dev/null
  find src/backend/utils/misc -name 'guc-file.c' 2>/dev/null
  # Catalog and node generated headers
  find src/include/catalog -name '*.h' 2>/dev/null
  find src/backend/nodes -name '*.h' -o -name '*.funcs' 2>/dev/null
  find src/backend/utils -name '*.h' 2>/dev/null
  find src/include/storage -name 'lwlocknames.h' 2>/dev/null
  find src/backend/storage/lmgr -name 'lwlocknames.h' -o -name 'lwlocknames.c' 2>/dev/null
} > "$GENERATED_FILES" 2>/dev/null || true

###############################################################################
# Clean .o files but keep generated .c/.h and Makefiles
###############################################################################

echo "[postgres] [wasm] cleaning host-built .o and .a files..."
find src -name '*.o' -delete 2>/dev/null || true
find src -name '*.a' -delete 2>/dev/null || true
rm -f src/backend/postgres 2>/dev/null || true

# Verify key generated files survived the clean
for f in src/backend/parser/gram.c src/backend/parser/gram.h; do
  if [[ ! -f "$f" ]]; then
    echo "[postgres] ERROR: generated file $f missing after clean!" >&2
    exit 1
  fi
done
echo "[postgres] [wasm] generated files preserved OK"

rm -f "$GENERATED_FILES"

###############################################################################
# Pass 2: Cross-compile for wasm32-wasi
###############################################################################

echo "[postgres] ============================================"
echo "[postgres] Pass 2: WASM cross-compile"
echo "[postgres] ============================================"

# --- write config.cache.wasi ------------------------------------------------

CONFIG_CACHE="$PG_ROOT/config.cache.wasi"
cat > "$CONFIG_CACHE" << 'CACHEEOF'
# Pre-populated configure cache for wasm32-wasi cross-compilation.
# Values for wasm32 ILP32 model.

# Type sizes
ac_cv_sizeof_void_p=${ac_cv_sizeof_void_p=4}
ac_cv_sizeof_long=${ac_cv_sizeof_long=4}
ac_cv_sizeof_size_t=${ac_cv_sizeof_size_t=4}
ac_cv_sizeof_off_t=${ac_cv_sizeof_off_t=8}
ac_cv_sizeof_bool=${ac_cv_sizeof_bool=1}
ac_cv_sizeof_long_long_int=${ac_cv_sizeof_long_long_int=8}

# Alignments
ac_cv_alignof_short=${ac_cv_alignof_short=2}
ac_cv_alignof_int=${ac_cv_alignof_int=4}
ac_cv_alignof_long=${ac_cv_alignof_long=4}
ac_cv_alignof_long_long_int=${ac_cv_alignof_long_long_int=8}
ac_cv_alignof_double=${ac_cv_alignof_double=8}

# Spinlock support (GCC builtins work on wasm)
pgac_cv_gcc_sync_char_tas=${pgac_cv_gcc_sync_char_tas=yes}
pgac_cv_gcc_sync_int32_tas=${pgac_cv_gcc_sync_int32_tas=yes}
pgac_cv_gcc_sync_int32_cas=${pgac_cv_gcc_sync_int32_cas=yes}
pgac_cv_gcc_sync_int64_cas=${pgac_cv_gcc_sync_int64_cas=yes}
pgac_cv_gcc_atomic_int32_cas=${pgac_cv_gcc_atomic_int32_cas=yes}
pgac_cv_gcc_atomic_int64_cas=${pgac_cv_gcc_atomic_int64_cas=yes}

# Functions provided by lind-wasm sysroot (tell configure they exist)
ac_cv_func_getifaddrs=${ac_cv_func_getifaddrs=yes}
ac_cv_func_posix_fallocate=${ac_cv_func_posix_fallocate=yes}
ac_cv_func_ppoll=${ac_cv_func_ppoll=yes}
ac_cv_func_sync_file_range=${ac_cv_func_sync_file_range=yes}
ac_cv_func_fork=${ac_cv_func_fork=yes}
ac_cv_func_vfork=${ac_cv_func_vfork=yes}
ac_cv_func_shmget=${ac_cv_func_shmget=yes}
ac_cv_func_getrlimit=${ac_cv_func_getrlimit=yes}
ac_cv_func_setrlimit=${ac_cv_func_setrlimit=yes}
ac_cv_func_syslog=${ac_cv_func_syslog=yes}
ac_cv_func_getpwuid_r=${ac_cv_func_getpwuid_r=yes}
ac_cv_func_getaddrinfo=${ac_cv_func_getaddrinfo=yes}
ac_cv_func_posix_fadvise=${ac_cv_func_posix_fadvise=yes}
ac_cv_func_kill=${ac_cv_func_kill=yes}
ac_cv_func_getrusage=${ac_cv_func_getrusage=yes}
ac_cv_func_getpgrp=${ac_cv_func_getpgrp=yes}
ac_cv_func_setsid=${ac_cv_func_setsid=yes}

# Functions genuinely not available in WASI
ac_cv_func_shm_open=${ac_cv_func_shm_open=no}
ac_cv_func_dlopen=${ac_cv_func_dlopen=no}
ac_cv_func_setproctitle=${ac_cv_func_setproctitle=no}
ac_cv_func_setproctitle_fast=${ac_cv_func_setproctitle_fast=no}
ac_cv_func_getpeereid=${ac_cv_func_getpeereid=no}
pgac_cv_rint_is_c99_compliant=${pgac_cv_rint_is_c99_compliant=yes}
ac_cv_working_alloca=${ac_cv_working_alloca=yes}

# Printf format checks — assume C99 compliant
pgac_cv_snprintf_long_long_int_modifier=${pgac_cv_snprintf_long_long_int_modifier=ll}
pgac_cv_snprintf_size_t_support=${pgac_cv_snprintf_size_t_support=yes}

# Large file support
ac_cv_sys_largefile_CC=${ac_cv_sys_largefile_CC=no}

# Shared memory type — sysroot provides sysv shm
pgac_cv_ipc_shmem_kind=${pgac_cv_ipc_shmem_kind=sysv}
PREFERRED_SEMAPHORES=${PREFERRED_SEMAPHORES=UNNAMED_POSIX}

# Locale — minimal support
ac_cv_func_localeconv=${ac_cv_func_localeconv=no}
pgac_cv_type_locale_t=${pgac_cv_type_locale_t=no}
CACHEEOF

echo "[postgres] [wasm] wrote config cache: $CONFIG_CACHE"

# --- Cross-configure ---------------------------------------------------------

echo "[postgres] [wasm] configuring for wasm32-wasi..."

./configure \
  --host=wasm32-unknown-linux-gnu \
  --build="$(./config/config.guess)" \
  --with-template=linux \
  --with-system-tzdata=/usr/share/zoneinfo \
  --cache-file="$CONFIG_CACHE" \
  --without-readline \
  --without-icu \
  --without-systemd \
  --without-pam \
  --without-ldap \
  --without-gssapi \
  --without-bonjour \
  --without-selinux \
  --without-zlib \
  --without-lz4 \
  --without-zstd \
  --without-llvm \
  --without-libcurl \
  --without-libnuma \
  --without-liburing \
  --disable-dtrace \
  --disable-nls \
  --disable-tap-tests \
  --disable-thread-safety \
  --disable-rpath \
  --disable-spinlocks \
  CC="$CC_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  NM="$NM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_CONFIGURE" \
  PKG_CONFIG=false

# --- Post-configure fixups ---------------------------------------------------

# For static builds, disable shared library targets since we only need .a files.
# For dylink builds, we build .a files first then convert them to shared .wasm
# in a post-build step (postgres's native shared lib build doesn't work for WASM).
MAKEFILE_SHLIB="$PG_ROOT/src/Makefile.shlib"
if [[ -f "$MAKEFILE_SHLIB" ]]; then
  echo "[postgres] [wasm] patching Makefile.shlib to disable native shared libraries..."
  sed -i 's/^all-lib: all-shared-lib/#all-lib: all-shared-lib  # disabled for WASI/' "$MAKEFILE_SHLIB"
fi

# Patch libpq's Makefile: libpq-refs-stamp depends on $(shlib) and runs a
# Perl symbol check. Since we don't build native shared libs, remove the dependency.
LIBPQ_MAKEFILE="$PG_ROOT/src/interfaces/libpq/Makefile"
if [[ -f "$LIBPQ_MAKEFILE" ]]; then
  echo "[postgres] [wasm] patching libpq Makefile to skip shared-lib ref check..."
  sed -i '/^libpq-refs-stamp:/,/touch \$@/{
    s/^libpq-refs-stamp: .*/libpq-refs-stamp:/
  }' "$LIBPQ_MAKEFILE"
fi

PG_CONFIG_H="$PG_ROOT/src/include/pg_config.h"

if [[ -f "$PG_CONFIG_H" ]]; then
  echo "[postgres] [wasm] patching pg_config.h for WASI..."

  # Force USE_UNNAMED_POSIX_SEMAPHORES off if set — we stub semaphores
  if grep -q '#define USE_UNNAMED_POSIX_SEMAPHORES' "$PG_CONFIG_H"; then
    sed -i 's/#define USE_UNNAMED_POSIX_SEMAPHORES.*$/\/* #undef USE_UNNAMED_POSIX_SEMAPHORES -- disabled for WASI *\//' "$PG_CONFIG_H"
  fi

  # Force USE_NAMED_POSIX_SEMAPHORES off
  if grep -q '#define USE_NAMED_POSIX_SEMAPHORES' "$PG_CONFIG_H"; then
    sed -i 's/#define USE_NAMED_POSIX_SEMAPHORES.*$/\/* #undef USE_NAMED_POSIX_SEMAPHORES -- disabled for WASI *\//' "$PG_CONFIG_H"
  fi

  # Force USE_SYSV_SEMAPHORES off
  if grep -q '#define USE_SYSV_SEMAPHORES' "$PG_CONFIG_H"; then
    sed -i 's/#define USE_SYSV_SEMAPHORES.*$/\/* #undef USE_SYSV_SEMAPHORES -- disabled for WASI *\//' "$PG_CONFIG_H"
  fi

  # Ensure HAVE_SPINLOCKS is defined (GCC builtins work on wasm)
  if ! grep -q '#define HAVE_SPINLOCKS' "$PG_CONFIG_H"; then
    echo '#define HAVE_SPINLOCKS 1' >> "$PG_CONFIG_H"
  fi

  # Force signalfd off — not implemented in lind-wasm
  if grep -q '#define HAVE_SYS_SIGNALFD_H' "$PG_CONFIG_H"; then
    echo "[postgres] [wasm] disabling signalfd in pg_config.h..."
    sed -i 's/#define HAVE_SYS_SIGNALFD_H.*$/\/* #undef HAVE_SYS_SIGNALFD_H -- disabled for WASI *\//' "$PG_CONFIG_H"
  fi
fi

# --- Compile WASI stubs -----------------------------------------------------

WASI_STUBS_C="$PG_ROOT/wasi_stubs.c"
WASI_STUBS_O="$PG_ROOT/wasi_stubs.o"

if [[ ! -f "$WASI_STUBS_C" ]]; then
  echo "[postgres] ERROR: missing postgres/wasi_stubs.c (it should be committed in the repo)." >&2
  exit 1
fi

echo "[postgres] [wasm] compiling WASI stubs..."
$CC_WASM $CFLAGS_WASM -c "$WASI_STUBS_C" -o "$WASI_STUBS_O"

###############################################################################
# Build backend (best-effort)
###############################################################################

echo "[postgres] [wasm] building port library..."
make -C src/port -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" || true

echo "[postgres] [wasm] building common library..."
make -C src/common -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" || true

echo "[postgres] [wasm] building src/backend..."
make -C src/backend all -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="$WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: backend build had errors (best-effort, continuing)."
}

###############################################################################
# Build initdb and its dependencies (best-effort)
###############################################################################

echo "[postgres] [wasm] building libpq..."
make -C src/interfaces/libpq -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" || {
    echo "[postgres] WARNING: libpq build had errors (best-effort, continuing)."
}

echo "[postgres] [wasm] building fe_utils..."
make -C src/fe_utils -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="$LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" || {
    echo "[postgres] WARNING: fe_utils build had errors (best-effort, continuing)."
}

echo "[postgres] [wasm] building initdb..."
make -C src/bin/initdb -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="-L$PG_ROOT/src/port -L$PG_ROOT/src/common -L$PG_ROOT/src/fe_utils -L$PG_ROOT/src/interfaces/libpq $LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="-lpgfeutils -lpq -lpgcommon -lpgport $WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: initdb build had errors (best-effort, continuing)."
}

# pgbench uses ppoll() by default, but ppoll is broken in lind-wasm glibc
# (SYSCALL_CANCEL returns 0 immediately). Force select() instead.
echo "[postgres] [wasm] building pgbench..."
make -C src/bin/pgbench -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM -DPGBENCH_USE_SELECT" \
  LDFLAGS="-L$PG_ROOT/src/port -L$PG_ROOT/src/common -L$PG_ROOT/src/fe_utils -L$PG_ROOT/src/interfaces/libpq $LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="-lpgfeutils -lpq -lpgcommon -lpgport -lpgcommon $WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: pgbench build had errors (best-effort, continuing)."
}

###############################################################################
# Build shared libraries for dylink mode
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[postgres] [dylink] converting static libraries to shared WASM modules..."

  # Shared library output directory
  PG_SHARED_LIB_DIR="$STAGE_DIR/lib"
  mkdir -p "$PG_SHARED_LIB_DIR"

  # Libraries to convert: libpq is the main one needed by client tools
  # libpgport and libpgcommon are typically linked statically into binaries
  declare -A PG_SHARED_LIBS=(
    ["pq"]="$PG_ROOT/src/interfaces/libpq/libpq.a"
  )

  for lib_name in "${!PG_SHARED_LIBS[@]}"; do
    STATIC_LIB="${PG_SHARED_LIBS[$lib_name]}"
    if [[ ! -f "$STATIC_LIB" ]]; then
      echo "[postgres] [dylink] WARNING: $STATIC_LIB not found, skipping lib${lib_name}.so"
      continue
    fi

    SHARED_WASM="$PG_SHARED_LIB_DIR/lib${lib_name}.wasm"
    SHARED_OPT="$PG_SHARED_LIB_DIR/lib${lib_name}.opt.wasm"
    SHARED_CWASM="$PG_SHARED_LIB_DIR/lib${lib_name}.opt.cwasm"
    SHARED_STAGED="$PG_SHARED_LIB_DIR/lib${lib_name}.so"

    echo "[postgres] [dylink] linking lib${lib_name}.a -> lib${lib_name}.wasm..."
    "$CLANG" \
      --target=wasm32-unknown-wasi \
      --sysroot="$MERGED_SYSROOT" \
      -fPIC \
      -fvisibility=default \
      -Wl,--import-memory \
      -Wl,--shared-memory \
      -Wl,--export-dynamic \
      -Wl,--experimental-pic \
      -Wl,--unresolved-symbols=import-dynamic \
      -Wl,-shared \
      -Wl,--whole-archive "$STATIC_LIB" -Wl,--no-whole-archive \
      -L"$MERGED_SYSROOT/lib/wasm32-wasi" \
      -g -O2 \
      -o "$SHARED_WASM" || {
        echo "[postgres] [dylink] WARNING: failed to link lib${lib_name}.wasm"
        continue
      }

    echo "[postgres] [dylink] adding exports to lib${lib_name}.wasm..."
    "$ADD_EXPORT_TOOL" "$SHARED_WASM" "$SHARED_WASM" \
      __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional || true
    "$ADD_EXPORT_TOOL" "$SHARED_WASM" "$SHARED_WASM" \
      __wasm_apply_global_relocs func __wasm_apply_global_relocs optional || true
    "$ADD_EXPORT_TOOL" "$SHARED_WASM" "$SHARED_WASM" \
      __stack_pointer global __stack_pointer optional || true

    echo "[postgres] [dylink] running wasm-opt on lib${lib_name}.wasm..."
    "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --epoch-injection --pass-arg=epoch-import \
      --asyncify --pass-arg=asyncify-import-globals \
      -O2 --debuginfo \
      "$SHARED_WASM" -o "$SHARED_OPT" || {
        echo "[postgres] [dylink] WARNING: wasm-opt failed for lib${lib_name}"
        continue
      }

    echo "[postgres] [dylink] precompiling lib${lib_name}.opt.wasm..."
    "$LIND_BOOT" --precompile "$SHARED_OPT" || {
      echo "[postgres] [dylink] WARNING: precompile failed for lib${lib_name}"
      continue
    }

    if [[ -f "$SHARED_CWASM" ]]; then
      cp "$SHARED_CWASM" "$SHARED_STAGED"
      echo "[postgres] [dylink] staged: $SHARED_STAGED"
    else
      echo "[postgres] [dylink] WARNING: $SHARED_CWASM not produced"
    fi
  done
fi

###############################################################################
# Stage binaries
###############################################################################

PG_BINARY="$PG_ROOT/src/backend/postgres"
INITDB_BINARY="$PG_ROOT/src/bin/initdb/initdb"
PGBENCH_BINARY="$PG_ROOT/src/bin/pgbench/pgbench"

STAGED_BINARIES=()

if [[ -f "$PG_BINARY" ]]; then
  cp "$PG_BINARY" "$STAGE_DIR/postgres.wasm"
  STAGED_BINARIES+=("postgres")
  echo "[postgres] staged: $STAGE_DIR/postgres.wasm"
else
  echo "[postgres] WARNING: postgres binary was not produced."
fi

if [[ -f "$INITDB_BINARY" ]]; then
  cp "$INITDB_BINARY" "$STAGE_DIR/initdb.wasm"
  STAGED_BINARIES+=("initdb")
  echo "[postgres] staged: $STAGE_DIR/initdb.wasm"
else
  echo "[postgres] WARNING: initdb binary was not produced."
fi

if [[ -f "$PGBENCH_BINARY" ]]; then
  cp "$PGBENCH_BINARY" "$STAGE_DIR/pgbench.wasm"
  STAGED_BINARIES+=("pgbench")
  echo "[postgres] staged: $STAGE_DIR/pgbench.wasm"
else
  echo "[postgres] WARNING: pgbench binary was not produced."
fi

if [[ ${#STAGED_BINARIES[@]} -eq 0 ]]; then
  echo "[postgres] No binaries were produced."
  echo "[postgres] This is expected during initial porting — check build errors above."
  exit 0
fi

###############################################################################
# wasm-opt + cwasm (best-effort, for each staged binary)
###############################################################################

for bin_name in "${STAGED_BINARIES[@]}"; do
  RAW_WASM="$STAGE_DIR/${bin_name}.wasm"
  OPT_WASM="$STAGE_DIR/${bin_name}.opt.wasm"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[postgres] running wasm-opt on ${bin_name} (asyncify + optimization)..."
    if [[ "$LIND_DYLINK" == "1" ]]; then
      # Dylink wasm-opt flags: import epoch/asyncify globals from shared libc
      # -O2 before asyncify helps reduce locals in large binaries like postgres
      "$WASM_OPT" \
        --enable-bulk-memory --enable-threads \
        -O2 \
        --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
        --asyncify --pass-arg=asyncify-import-globals \
        --debuginfo \
        "$RAW_WASM" \
        -o "$OPT_WASM" || {
          echo "[postgres] WARNING: wasm-opt failed for ${bin_name}; skipping optimization."
          continue
        }
    else
      # Static wasm-opt flags
      "$WASM_OPT" \
        --epoch-injection \
        --asyncify \
        --debuginfo \
        -O2 \
        "$RAW_WASM" \
        -o "$OPT_WASM" || {
          echo "[postgres] WARNING: wasm-opt failed for ${bin_name}; skipping optimization."
          continue
        }
    fi
  else
    echo "[postgres] NOTE: wasm-opt not found at '$WASM_OPT'; skipping optimization."
    continue
  fi

  # Dylink: add required exports via add-export-tool
  if [[ "$LIND_DYLINK" == "1" ]]; then
    echo "[postgres] adding dylink exports for ${bin_name}..."
    "$ADD_EXPORT_TOOL" "$OPT_WASM" "$OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
    "$ADD_EXPORT_TOOL" "$OPT_WASM" "$OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
    "$ADD_EXPORT_TOOL" "$OPT_WASM" "$OPT_WASM" __stack_pointer global __stack_pointer
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    echo "[postgres] generating cwasm for ${bin_name} via lind-boot --precompile..."
    if [[ -f "$OPT_WASM" ]]; then
      if "$LIND_BOOT" --precompile "$OPT_WASM"; then
        # Rename foo.opt.cwasm → foo.cwasm (drop .opt)
        OPT_CWASM="${OPT_WASM%.wasm}.cwasm"
        CLEAN_CWASM="${OPT_CWASM/.opt/}"
        if [[ "$OPT_CWASM" != "$CLEAN_CWASM" && -f "$OPT_CWASM" ]]; then
          mv "$OPT_CWASM" "$CLEAN_CWASM"
        fi
      else
        echo "[postgres] WARNING: lind-boot --precompile failed for ${bin_name}."
      fi
    fi
  else
    echo "[postgres] NOTE: lind-boot not found at '$LIND_BOOT'; skipping cwasm generation."
  fi
done

echo
echo "[postgres] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
