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
# Only the backend binary (postgres) is targeted.
# This is a best-effort port — link or build failures
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
STAGE_DIR="$APPS_BUILD/postgres"
STAGE_BIN="$STAGE_DIR/bin"
STAGE_SHARE="$STAGE_DIR/share"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
ADD_EXPORT_TOOL="${ADD_EXPORT_TOOL:-$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool}"

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

mkdir -p "$STAGE_BIN" "$STAGE_SHARE"

# --- WASM-specific source patches -------------------------------------------

echo "[postgres] applying WASM-specific source patches..."

# Re-enable plpgsql if it was previously disabled (we now use dynamic loading)
if grep -q "// load_plpgsql(cmdfd);" "$PG_ROOT/src/bin/initdb/initdb.c"; then
  sed -i 's|// load_plpgsql(cmdfd); // Disabled for WASM - no shared library extensions|load_plpgsql(cmdfd);|' "$PG_ROOT/src/bin/initdb/initdb.c"
  echo "[postgres] patched initdb.c: re-enabled plpgsql (dynamic loading)"
fi

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
  CFLAGS_WASM="$CFLAGS_WASM -fPIC -fvisibility=default"

  # Extra CRT objects required for dynamic PIE executables
  DYLINK_CRT_OBJS=(
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
    -Wl,--export-dynamic \
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
ac_cv_func_dlopen=${ac_cv_func_dlopen=yes}
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

grep -q "wasi_stubs" "$PG_ROOT/src/backend/Makefile" || echo "OBJS += $WASI_STUBS_O" >> "$PG_ROOT/src/backend/Makefile"

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
  LIBS="-Wl,--whole-archive $WASI_STUBS_O -Wl,--no-whole-archive -lm" || {
    echo "[postgres] ERROR: backend build failed."
    exit 1
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

echo "[postgres] [wasm] building pgbench..."
make -C src/bin/pgbench -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="-L$PG_ROOT/src/port -L$PG_ROOT/src/common -L$PG_ROOT/src/fe_utils -L$PG_ROOT/src/interfaces/libpq $LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="-lpgfeutils -lpq -lpgcommon -lpgport -lpgcommon $WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: pgbench build had errors (best-effort, continuing)."
}

echo "[postgres] [wasm] building psql..."
make -C src/bin/psql -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM" \
  LDFLAGS="-L$PG_ROOT/src/port -L$PG_ROOT/src/common -L$PG_ROOT/src/fe_utils -L$PG_ROOT/src/interfaces/libpq $LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="-lpgfeutils -lpq -lpgcommon -lpgport -lpgcommon $WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: psql build had errors (best-effort, continuing)."
}

echo "[postgres] [wasm] building pg_regress..."
make -C src/test/regress -j"$JOBS" \
  CC="$CC_WASM" \
  CFLAGS="$CFLAGS_WASM -I$PG_ROOT/src/port -I$PG_ROOT/src/interfaces/libpq -DHOST_TUPLE=\"wasm32-unknown-wasi\" -DSHELLPROG=\"/bin/sh\"" \
  LDFLAGS="-L$PG_ROOT/src/port -L$PG_ROOT/src/common -L$PG_ROOT/src/interfaces/libpq $LDFLAGS_WASM" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  LIBS="-lpq -lpgcommon -lpgport -lpgcommon $WASI_STUBS_O -lm" || {
    echo "[postgres] WARNING: pg_regress build had errors (best-effort, continuing)."
}

###############################################################################
# Build plpgsql as shared WASM library (for dynamic loading via dlopen)
# Only built for dynamic linking mode since it requires dlopen support.
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
echo "[postgres] [wasm] building plpgsql shared library..."
PLPGSQL_DIR="$PG_ROOT/src/pl/plpgsql/src"
PLPGSQL_LIB_DIR="$STAGE_DIR/lib"
mkdir -p "$PLPGSQL_LIB_DIR"

# Generate plpgsql parser and error codes (uses host perl, already done in Pass 1)
make -C "$PLPGSQL_DIR" pl_gram.c plerrcodes.h pl_reserved_kwlist_d.h pl_unreserved_kwlist_d.h 2>/dev/null || true

# Build plpgsql objects with PIC for shared library
PLPGSQL_OBJS=""
for src in pl_comp.c pl_exec.c pl_funcs.c pl_gram.c pl_handler.c pl_scanner.c; do
  obj="${src%.c}.o"
  echo "[postgres] [wasm]   compiling $src (PIC)..."
  $CC_WASM $CFLAGS_WASM -fPIC \
    -I"$PLPGSQL_DIR" \
    -I"$PG_ROOT/src/include" \
    -c "$PLPGSQL_DIR/$src" -o "$PLPGSQL_DIR/$obj" || {
      echo "[postgres] WARNING: failed to compile $src"
      continue
    }
  PLPGSQL_OBJS="$PLPGSQL_OBJS $PLPGSQL_DIR/$obj"
done

# Link as shared WASM library
if [[ -n "$PLPGSQL_OBJS" ]]; then
  echo "[postgres] [wasm] linking plpgsql.wasm..."
  PLPGSQL_WASM="$PLPGSQL_LIB_DIR/plpgsql.wasm"
  PLPGSQL_OPT="$PLPGSQL_LIB_DIR/plpgsql.opt.wasm"

  "$CLANG" \
    --target=wasm32-unknown-wasi \
    --sysroot="$MERGED_SYSROOT" \
    -fPIC \
    -Wl,-shared \
    -Wl,--import-memory \
    -Wl,--shared-memory \
    -Wl,--export-dynamic \
    -Wl,--experimental-pic \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,--export=Pg_magic_func \
    -Wl,--export=_PG_init \
    -Wl,--export=plpgsql_call_handler \
    -Wl,--export=plpgsql_inline_handler \
    -Wl,--export=plpgsql_validator \
    -L"$MERGED_SYSROOT/lib/wasm32-wasi" \
    -g -O2 \
    $PLPGSQL_OBJS \
    -o "$PLPGSQL_WASM" || {
      echo "[postgres] WARNING: failed to link plpgsql.wasm"
    }

  echo "[postgres] [wasm] running wasm-opt on plpgsql.wasm..."
  "$WASM_OPT" \
    --enable-bulk-memory --enable-threads \
    --fpcast-emu --pass-arg=relocatable-fpcast \
    --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
    --asyncify --pass-arg=asyncify-import-globals \
    -O2 --debuginfo \
    "$PLPGSQL_WASM" -o "$PLPGSQL_OPT" || {
      echo "[postgres] WARNING: wasm-opt failed for plpgsql"
    }

  echo "[postgres] [wasm] adding exports to plpgsql.opt.wasm..."
  "$ADD_EXPORT_TOOL" "$PLPGSQL_OPT" "$PLPGSQL_OPT" \
    __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$PLPGSQL_OPT" "$PLPGSQL_OPT" \
    __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$PLPGSQL_OPT" "$PLPGSQL_OPT" \
    __stack_pointer global __stack_pointer optional

  # Stage the optimized wasm and create .so symlink (PostgreSQL looks for $libdir/plpgsql.so)
  if [[ -f "$PLPGSQL_OPT" ]]; then
    mv "$PLPGSQL_OPT" "$PLPGSQL_WASM"
    ln -sf plpgsql.wasm "$PLPGSQL_LIB_DIR/plpgsql.so"
    echo "[postgres] staged: $PLPGSQL_LIB_DIR/plpgsql.so -> plpgsql.wasm"
  fi
else
  echo "[postgres] WARNING: no plpgsql objects built"
fi  # end if [[ -n "$PLPGSQL_OBJS" ]]
else
  echo "[postgres] skipping plpgsql build (requires LIND_DYLINK=1)"
fi  # end if [[ "$LIND_DYLINK" == "1" ]] (plpgsql section)

###############################################################################
# Build shared libraries for dylink mode
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[postgres] [dylink] converting static libraries to shared WASM modules..."

  # Shared library output directory
  PG_SHARED_LIB_DIR="$STAGE_DIR/lib"
  mkdir -p "$PG_SHARED_LIB_DIR"
  mkdir -p "$STAGE_BIN" "$STAGE_SHARE"

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

    echo "[postgres] [dylink] running wasm-opt on lib${lib_name}.wasm..."
    "$WASM_OPT" \
      --enable-bulk-memory --enable-threads \
      --fpcast-emu --pass-arg=relocatable-fpcast \
      --epoch-injection --pass-arg=epoch-import \
      --asyncify --pass-arg=asyncify-import-globals \
      -O2 --debuginfo \
      "$SHARED_WASM" -o "$SHARED_OPT" || {
        echo "[postgres] [dylink] WARNING: wasm-opt failed for lib${lib_name}"
        continue
      }

    echo "[postgres] [dylink] adding exports to lib${lib_name}.opt.wasm..."
    "$ADD_EXPORT_TOOL" "$SHARED_OPT" "$SHARED_OPT" \
      __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
    "$ADD_EXPORT_TOOL" "$SHARED_OPT" "$SHARED_OPT" \
      __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
    "$ADD_EXPORT_TOOL" "$SHARED_OPT" "$SHARED_OPT" \
      __stack_pointer global __stack_pointer optional

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
PSQL_BINARY="$PG_ROOT/src/bin/psql/psql"
PG_REGRESS_BINARY="$PG_ROOT/src/test/regress/pg_regress"

STAGED_BINARIES=()

if [[ -f "$PG_BINARY" ]]; then
  cp "$PG_BINARY" "$STAGE_BIN/postgres.wasm"
  STAGED_BINARIES+=("postgres")
  echo "[postgres] staged: $STAGE_BIN/postgres.wasm"
else
  echo "[postgres] WARNING: postgres binary was not produced."
  exit 1
fi

if [[ -f "$INITDB_BINARY" ]]; then
  cp "$INITDB_BINARY" "$STAGE_BIN/initdb.wasm"
  STAGED_BINARIES+=("initdb")
  echo "[postgres] staged: $STAGE_BIN/initdb.wasm"
else
  echo "[postgres] WARNING: initdb binary was not produced."
fi

if [[ -f "$PGBENCH_BINARY" ]]; then
  cp "$PGBENCH_BINARY" "$STAGE_BIN/pgbench.wasm"
  STAGED_BINARIES+=("pgbench")
  echo "[postgres] staged: $STAGE_BIN/pgbench.wasm"
else
  echo "[postgres] WARNING: pgbench binary was not produced."
fi

if [[ -f "$PSQL_BINARY" ]]; then
  cp "$PSQL_BINARY" "$STAGE_BIN/psql.wasm"
  STAGED_BINARIES+=("psql")
  echo "[postgres] staged: $STAGE_BIN/psql.wasm"
else
  echo "[postgres] WARNING: psql binary was not produced."
fi

if [[ -f "$PG_REGRESS_BINARY" ]]; then
  cp "$PG_REGRESS_BINARY" "$STAGE_BIN/pg_regress.wasm"
  STAGED_BINARIES+=("pg_regress")
  echo "[postgres] staged: $STAGE_BIN/pg_regress.wasm"
else
  echo "[postgres] WARNING: pg_regress binary was not produced."
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
  RAW_WASM="$STAGE_BIN/${bin_name}.wasm"
  OPT_WASM="$STAGE_BIN/${bin_name}.opt.wasm"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[postgres] running wasm-opt on ${bin_name} (asyncify + optimization)..."
    if [[ "$LIND_DYLINK" == "1" ]]; then
      # Dylink wasm-opt flags: import epoch/asyncify globals from shared libc
      # -O2 before asyncify helps reduce locals in large binaries like postgres
      # NOTE: --pass-arg=relocatable-fpcast omitted for main binary — crashes
      # wasm-opt on binaries this large. Shared libs (plpgsql, libpq) keep it.
      "$WASM_OPT" \
        --enable-bulk-memory --enable-threads \
        --fpcast-emu \
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
        --fpcast-emu \
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
echo "  $STAGE_BIN"
ls -lh "$STAGE_BIN" || true

# ============================================================================
# Stage share files required by initdb/postgres
# ============================================================================
echo
echo "[postgres] staging share files..."

mkdir -p "$STAGE_SHARE/timezonesets"
mkdir -p "$STAGE_SHARE/extension"
mkdir -p "$STAGE_SHARE/tsearch_data"

# Core catalog files
cp "$PG_ROOT/src/include/catalog/postgres.bki" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: postgres.bki not found"
cp "$PG_ROOT/src/include/catalog/system_constraints.sql" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: system_constraints.sql not found"
cp "$PG_ROOT/src/backend/catalog/system_functions.sql" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: system_functions.sql not found"
cp "$PG_ROOT/src/backend/catalog/information_schema.sql" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: information_schema.sql not found"
cp "$PG_ROOT/src/backend/catalog/sql_features.txt" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: sql_features.txt not found"
cp "$PG_ROOT/src/backend/catalog/system_views.sql" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: system_views.sql not found"

# Stub snowball (text search extension not supported in WASM)
echo "-- Snowball text search disabled for WASM" > "$STAGE_SHARE/snowball_create.sql"
echo "[postgres] created stub snowball_create.sql"

# plpgsql extension files (dynamically loaded via dlopen)
cp "$PG_ROOT/src/pl/plpgsql/src/plpgsql.control" "$STAGE_SHARE/extension/" 2>/dev/null || echo "[postgres] WARNING: plpgsql.control not found"
cp "$PG_ROOT/src/pl/plpgsql/src/plpgsql--1.0.sql" "$STAGE_SHARE/extension/" 2>/dev/null || echo "[postgres] WARNING: plpgsql--1.0.sql not found"
echo "[postgres] staged plpgsql extension files"

# Config samples
cp "$PG_ROOT/src/backend/utils/misc/postgresql.conf.sample" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: postgresql.conf.sample not found"
cp "$PG_ROOT/src/backend/libpq/pg_hba.conf.sample" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: pg_hba.conf.sample not found"
cp "$PG_ROOT/src/backend/libpq/pg_ident.conf.sample" "$STAGE_SHARE/" 2>/dev/null || echo "[postgres] WARNING: pg_ident.conf.sample not found"

# Timezone sets
if [[ -d "$PG_ROOT/src/timezone/tznames" ]]; then
  cp "$PG_ROOT/src/timezone/tznames"/*.txt "$STAGE_SHARE/timezonesets/" 2>/dev/null || true
  cp -r "$PG_ROOT/src/timezone/tznames/Australia" "$STAGE_SHARE/timezonesets/" 2>/dev/null || true
  cp -r "$PG_ROOT/src/timezone/tznames/India" "$STAGE_SHARE/timezonesets/" 2>/dev/null || true
  cp "$PG_ROOT/src/timezone/tznames/Default" "$STAGE_SHARE/timezonesets/" 2>/dev/null || true
  echo "[postgres] copied timezone sets"
else
  echo "[postgres] WARNING: timezone tznames directory not found"
fi

echo "[postgres] share files staged at: $STAGE_SHARE"
ls -la "$STAGE_SHARE" || true

# ============================================================================
# Create lind-wasm optimized postgresql.conf
# ============================================================================
echo
echo "[postgres] creating lind-wasm postgresql.conf..."
cat > "$STAGE_SHARE/postgresql.conf.lind" << 'PGCONF'
# PostgreSQL configuration for lind-wasm
# These settings are required for stable operation

# Disable parallel workers (shared memory mapping issues in lind-wasm)
max_parallel_workers_per_gather = 0
max_parallel_workers = 0

# Use synchronous I/O (async I/O hangs in lind-wasm)
io_method = 'sync'
PGCONF
echo "[postgres] created: $STAGE_SHARE/postgresql.conf.lind"

# ============================================================================
# Stage timezone data
# ============================================================================
echo
echo "[postgres] staging timezone data..."
STAGE_ZONEINFO="$STAGE_DIR/usr/share/zoneinfo"
mkdir -p "$STAGE_ZONEINFO"
if [[ -d /usr/share/zoneinfo ]]; then
  cp -r /usr/share/zoneinfo/* "$STAGE_ZONEINFO/" 2>/dev/null || true
  echo "[postgres] copied timezone data to: $STAGE_ZONEINFO"
else
  echo "[postgres] WARNING: /usr/share/zoneinfo not found on host"
fi

# ============================================================================
# Stage pg_regress test files
# ============================================================================
echo
echo "[postgres] staging pg_regress test files..."
STAGE_REGRESS="$STAGE_DIR/regress"
mkdir -p "$STAGE_REGRESS"
if [[ -d "$PG_ROOT/src/test/regress" ]]; then
  cp -r "$PG_ROOT/src/test/regress/sql" "$STAGE_REGRESS/" 2>/dev/null || true
  cp -r "$PG_ROOT/src/test/regress/expected" "$STAGE_REGRESS/" 2>/dev/null || true
  cp -r "$PG_ROOT/src/test/regress/data" "$STAGE_REGRESS/" 2>/dev/null || true
  cp "$PG_ROOT/src/test/regress/parallel_schedule" "$STAGE_REGRESS/" 2>/dev/null || true
  echo "[postgres] copied pg_regress files to: $STAGE_REGRESS"

  # Generate serial_schedule from parallel_schedule: one test per line, skip float8.
  if [[ -f "$STAGE_REGRESS/parallel_schedule" ]]; then
    grep -v "^#" "$STAGE_REGRESS/parallel_schedule" \
      | sed 's/test: //' \
      | tr ' ' '\n' \
      | grep -v "^$" \
      | grep -v "float8" \
      | sed 's/^/test: /' > "$STAGE_REGRESS/serial_schedule"
    echo "[postgres] generated: $STAGE_REGRESS/serial_schedule"
  fi
else
  echo "[postgres] WARNING: pg_regress source not found"
fi

# ============================================================================
# Stage stub /dev/urandom and /dev/random (postgres reads these for auth tokens)
# NOTE: This is a static 1KB file, not a real entropy source. Once postgres
# reads through the 1KB, it gets repeated bytes. Fine for testing only.
# ============================================================================
echo
echo "[postgres] staging stub /dev/urandom and /dev/random..."
STAGE_DEV="$STAGE_DIR/dev"
mkdir -p "$STAGE_DEV"
dd if=/dev/urandom of="$STAGE_DEV/urandom" bs=1024 count=1 status=none
cp "$STAGE_DEV/urandom" "$STAGE_DEV/random"
echo "[postgres] staged stub: $STAGE_DEV/{urandom,random}"

# ============================================================================
# Create copies for binaries
# ============================================================================
echo
echo "[postgres] creating binary copies (without .cwasm extension)..."
cd "$STAGE_BIN"
for bin_name in "${STAGED_BINARIES[@]}"; do
  if [[ -f "${bin_name}.cwasm" ]]; then
    cp "${bin_name}.cwasm" "${bin_name}"
    chmod +x "${bin_name}"
    echo "[postgres] copy: ${bin_name}.cwasm -> ${bin_name}"
  fi
done
cd - >/dev/null

echo
echo "[postgres] install with: make install-postgres"
echo "[postgres] initialize with: lind-wasm --enable-fpcast /bin/initdb.cwasm -D /tmp/pgdata -c max_parallel_workers=0 -c max_parallel_workers_per_gather=0 -c io_method=sync"
