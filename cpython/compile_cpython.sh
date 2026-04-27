#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CPython WASI build helper for lind-wasm-apps
#
# High-level strategy:
#   1. Build a native host python (needed for cross-compilation)
#   2. Cross-compile CPython for wasm32-wasi
#   3. Optimize with wasm-opt (asyncify)
#   4. Precompile with lind-boot
#   5. If LIND_DYLINK=1, also build shared libpython and a PIE python binary
#
# Supports both Static (default) and Dynamic (LIND_DYLINK=1) builds.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_BUILD="$APPS_ROOT/build"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT to parent directory (layout: lind-wasm/lind-wasm-apps)
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

SYSROOT="${SYSROOT:-$APPS_BUILD/sysroot_merged}"
WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
ADD_EXPORT_TOOL="${ADD_EXPORT_TOOL:-$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"
# Build mode: "wasi" (default, standard WASI target) or "linux" (ac_sys_system=Linux,
# separate LINKFORSHARED, required for running Python under lind-wasm Linux syscall ABI)
LIND_BUILD_MODE="${LIND_BUILD_MODE:-wasi}"

# Load toolchain from Makefile preflight
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[cpython] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
AR="${AR:-"$LLVM_BIN_DIR/llvm-ar"}"
RANLIB="${RANLIB:-"$LLVM_BIN_DIR/llvm-ranlib"}"

# Output location
PYTHON_OUT_DIR="$APPS_BUILD/cpython"
BUILD_WASM="$SCRIPT_DIR/build-wasm"

# Sanity
if [[ ! -d "$SYSROOT" ]]; then
  echo "[cpython] ERROR: merged sysroot '$SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$PYTHON_OUT_DIR"

echo "[cpython] using CLANG       = $CLANG"
echo "[cpython] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[cpython] merged sysroot    = $SYSROOT"
echo "[cpython] output dir        = $PYTHON_OUT_DIR"
echo "[cpython] LIND_DYLINK       = $LIND_DYLINK"
echo "[cpython] LIND_BUILD_MODE  = $LIND_BUILD_MODE"
echo

###############################################################################
# 1. Build native host python (needed for cross-compilation)
###############################################################################

"$SCRIPT_DIR/build_python_native.sh"

###############################################################################
# 2. Create WASI placeholder libraries and configure/build wasm python
###############################################################################

# Linker flags split out for linux mode (LINKFORSHARED / BLDSHARED) so that
# CPython's build system applies them only at final link time, not per-object.
WASM_MAIN_LDFLAGS="-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low"
WASM_SHARED_LDFLAGS="-Wl,--import-memory,--shared-memory,--export-dynamic,--experimental-pic,--unresolved-symbols=import-dynamic,-shared"

# CC passed to configure differs by mode:
#   wasi: embed linker flags in CC (current behaviour, CPython's WASI build expects this)
#   linux: bare CC without linker flags; LINKFORSHARED/BLDSHARED carry them instead
if [[ "$LIND_BUILD_MODE" == "linux" ]]; then
  CONFIGURE_CC="$CLANG -pthread --target=wasm32-unknown-wasi --sysroot $SYSROOT -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC"
else
  CONFIGURE_CC="$CLANG -pthread --target=wasm32-unknown-wasi --sysroot $SYSROOT $WASM_MAIN_LDFLAGS -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC"
fi

# These empty archives satisfy configure checks for WASI-unavailable libraries.
WASI_STUB_DIR="$SYSROOT/lib/wasm32-wasi"
mkdir -p "$WASI_STUB_DIR"
for lib in libwasi-emulated-getpid.a libwasi-emulated-signal.a libwasi-emulated-process-clocks.a; do
  if [[ ! -f "$WASI_STUB_DIR/$lib" ]]; then
    "$AR" crs "$WASI_STUB_DIR/$lib"
  fi
done

mkdir -p "$BUILD_WASM"
pushd "$BUILD_WASM" >/dev/null

# CPython uses -O0 because the build system relies on specific code generation
# behavior that breaks with optimization.

if [[ ! -f "Makefile" ]]; then
  echo "[cpython] configuring wasm build (mode: $LIND_BUILD_MODE)..."

  # Patch CPython's configure to report the correct OS to the build system.
  # In linux mode CPython enables Linux-specific code paths required by lind-wasm.
  # In wasi mode restore the upstream default.
  if [[ "$LIND_BUILD_MODE" == "linux" ]]; then
    sed -i '/\*-\*-wasi\*)/,/;;/{s/ac_sys_system=WASI/ac_sys_system=Linux/}' "$SCRIPT_DIR/configure"
  else
    sed -i '/\*-\*-wasi\*)/,/;;/{s/ac_sys_system=Linux/ac_sys_system=WASI/}' "$SCRIPT_DIR/configure"
  fi

  EXTRA_CONFIGURE_ARGS=()
  if [[ "$LIND_BUILD_MODE" == "linux" ]]; then
    EXTRA_CONFIGURE_ARGS+=(--disable-ipv6)
  fi

  ../configure \
    --host=wasm32-unknown-wasi \
    --build=x86_64-unknown-linux-gnu \
    --with-build-python=../build-native/python \
    CC="$CONFIGURE_CC" \
    ac_cv_func_working_mktime=yes \
    ac_cv_func_mmap_fixed_mapped=yes \
    bash_cv_func_sigsetjmp=no \
    ac_cv_func_localeconv=no \
    ac_cv_func_uselocale=no \
    ac_cv_func_setlocale=no \
    ac_cv_func_newlocale=no \
    ac_cv_have_chflags=no \
    ax_cv_c_float_words_bigendian=no \
    ac_cv_file__dev_ptmx=no \
    ac_cv_file__dev_ptc=no \
    ac_cv_func_memfd_create=no \
    ac_cv_func_eventfd=no \
    ac_cv_func_timerfd_create=no \
    ac_cv_libm_c99=yes \
    "${EXTRA_CONFIGURE_ARGS[@]}" \
    --verbose
fi

echo "[cpython] building wasm python..."

MAKE_OVERRIDES=(AR="$AR" ARFLAGS="crs")
if [[ "$LIND_BUILD_MODE" == "linux" ]]; then
  BARE_CC="$CLANG -pthread --target=wasm32-unknown-wasi --sysroot $SYSROOT -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC"
  MAKE_OVERRIDES+=(
    BLDSHARED="${BARE_CC} ${WASM_SHARED_LDFLAGS}"
    LINKFORSHARED="${WASM_MAIN_LDFLAGS}"
    ENSUREPIP=no
    MODULE__HMAC_LDFLAGS="Modules/_hacl/Hacl_HMAC.o Modules/_hacl/Hacl_Streaming_HMAC.o"
  )
fi

make "${MAKE_OVERRIDES[@]}" &> make.log || {
  echo "[cpython] ERROR: make failed. See $BUILD_WASM/make.log" >&2
  tail -20 make.log >&2
  exit 1
}

# Install python files into staging dir
make "${MAKE_OVERRIDES[@]}" install DESTDIR="$PYTHON_OUT_DIR"

###############################################################################
# 3. wasm-opt + precompile (static path)
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[cpython] Mode: DYNAMIC LINKING — skipping static wasm-opt/precompile"
else
  echo "[cpython] Mode: STATIC LINKING"

  PYTHON_WASM="$BUILD_WASM/python.wasm"
  PYTHON_OPT_WASM="$BUILD_WASM/python.opt.wasm"
  PYTHON_OPT_CWASM="$BUILD_WASM/python.opt.cwasm"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[cpython] running wasm-opt (asyncify + optimization)..."
    "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo \
      "$PYTHON_WASM" -o "$PYTHON_OPT_WASM"
  else
    echo "[cpython] ERROR: wasm-opt not found at '$WASM_OPT'" >&2
    exit 1
  fi

  if [[ ! -f "$PYTHON_OPT_WASM" ]]; then
    echo "[cpython] ERROR: Failed to generate $PYTHON_OPT_WASM" >&2
    exit 1
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    echo "[cpython] generating cwasm via lind-boot --precompile..."
    if "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM"; then
      if [[ -f "$PYTHON_OPT_CWASM" ]]; then
        mkdir -p "$PYTHON_OUT_DIR/usr/local/bin"
        cp "$PYTHON_OPT_CWASM" "$PYTHON_OUT_DIR/usr/local/bin/python"
        echo "[cpython] python staged as $PYTHON_OUT_DIR/usr/local/bin/python"
      else
        echo "[cpython] ERROR: No .cwasm binary generated." >&2
        exit 1
      fi
    else
      echo "[cpython] ERROR: lind-boot --precompile failed." >&2
      exit 1
    fi
  else
    echo "[cpython] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
    exit 1
  fi
fi

###############################################################################
# 4. Dynamic linking: build shared libpython + PIE python binary
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[cpython] building shared libpython..."

  if [[ ! -x "$ADD_EXPORT_TOOL" ]]; then
    echo "[cpython] ERROR: add-export-tool not found at '$ADD_EXPORT_TOOL'" >&2
    exit 1
  fi

  STATIC_LIB="$BUILD_WASM/libpython3.14.a"
  LIBMPDEC="$BUILD_WASM/Modules/_decimal/libmpdec/libmpdec.a"
  DYNAMIC_LIB_WASM="$BUILD_WASM/libpython3.14.wasm"
  DYNAMIC_LIB_OPT="$BUILD_WASM/libpython3.14.opt.wasm"
  DYNAMIC_LIB_OPT_CWASM="$BUILD_WASM/libpython3.14.opt.cwasm"
  DYNAMIC_STAGED_LIB="$PYTHON_OUT_DIR/lib/libpython3.14.so"
  mkdir -p "$PYTHON_OUT_DIR/lib" "$PYTHON_OUT_DIR/usr/local/bin"

  # In linux mode, libmpdec is not fully absorbed into the static lib so it must
  # be included in the --whole-archive group explicitly.
  EXTRA_WHOLE_ARCHIVE_ARGS=()
  if [[ "$LIND_BUILD_MODE" == "linux" ]]; then
    EXTRA_WHOLE_ARCHIVE_ARGS+=("$LIBMPDEC")
  fi

  # Build shared libpython
  "$CLANG" \
    --target=wasm32-unknown-wasi \
    -fPIC \
    --sysroot "$SYSROOT" \
    -fvisibility=default \
    -Wl,--import-memory \
    -Wl,--shared-memory \
    -Wl,--export-dynamic \
    -Wl,--experimental-pic \
    -Wl,--unresolved-symbols=import-dynamic \
    -Wl,-shared \
    -Wl,--whole-archive \
    "$STATIC_LIB" \
    "${EXTRA_WHOLE_ARCHIVE_ARGS[@]}" \
    -Wl,--no-whole-archive \
    -Wl,--export=__wasm_call_ctors \
    -Wl,--export-if-defined=__wasm_init_tls \
    -Wl,--export=__tls_base \
    "$SYSROOT/lib/wasm32-wasi/lind_utils.o" \
    -g -O0 -o "$DYNAMIC_LIB_WASM" \
    || { echo "[cpython] ERROR: shared libpython compilation failed" >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'" >&2
    exit 1
  fi

  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional \
    || { echo "[cpython] ERROR: add-export-tool tls failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional \
    || { echo "[cpython] ERROR: add-export-tool global failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __stack_pointer global __stack_pointer optional \
    || { echo "[cpython] ERROR: add-export-tool stack pointer failed" >&2; exit 1; }

  "$WASM_OPT" --enable-bulk-memory --enable-threads \
    --epoch-injection --pass-arg=epoch-import \
    --asyncify --pass-arg=asyncify-import-globals \
    -O2 --debuginfo \
    "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" \
    || { echo "[cpython] ERROR: wasm-opt failed on shared libpython" >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'" >&2
    exit 1
  fi

  "$LIND_BOOT" --precompile "$DYNAMIC_LIB_OPT" \
    || { echo "[cpython] ERROR: lind-boot --precompile failed for shared libpython" >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'" >&2
    exit 1
  fi

  cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
  echo "[cpython] shared libpython staged as $DYNAMIC_STAGED_LIB"

  # Build PIE python binary
  echo "[cpython] building PIE python binary..."

  # In linux mode the hacl hash modules are linked as part of the shared libpython
  # (via MODULE__HMAC_LDFLAGS during make), so they must not be re-linked here.
  # Arrays mirror the original WASI link order; linux mode omits the hacl archives.
  PIE_HACL_PRE=()   # hacl libs that appear before libexpat in WASI mode
  PIE_HACL_MID=()   # hacl libs that appear between libexpat and libmpdec in WASI mode
  PIE_HACL_POST=()  # hacl libs that appear after libmpdec in WASI mode
  if [[ "$LIND_BUILD_MODE" != "linux" ]]; then
    PIE_HACL_PRE=(
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA2.a"
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA1.a"
    )
    PIE_HACL_MID=(
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_MD5.a"
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_BLAKE2.a"
    )
    PIE_HACL_POST=(
      "$BUILD_WASM/Modules/_hacl/libHacl_HMAC.a"
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA3.a"
    )
  fi

  PYTHON_WASM="$BUILD_WASM/python_shared.wasm"
  PYTHON_OPT_WASM="$BUILD_WASM/python_shared.opt.wasm"
  PYTHON_OPT_CWASM="$BUILD_WASM/python_shared.opt.cwasm"

  "$CLANG" \
    -pthread \
    -fPIC \
    --target=wasm32-unknown-wasi \
    --sysroot "$SYSROOT" \
    -nostartfiles \
    -Wl,-pie \
    -Wl,--import-table \
    -Wl,--import-memory \
    -Wl,--export-memory \
    -Wl,--shared-memory \
    -Wl,--max-memory=67108864 \
    -Wl,--export=__stack_pointer \
    -Wl,--export=__stack_low \
    -Wl,--export=__wasm_call_ctors \
    -Wl,--export-if-defined=__wasm_init_tls \
    -Wl,--export=__tls_base \
    -Wl,--allow-undefined \
    -Wl,--unresolved-symbols=import-dynamic \
    -D _FILE_OFFSET_BITS=64 \
    -D __USE_LARGEFILE64 \
    -g -O0 \
    -o "$PYTHON_WASM" \
    "$BUILD_WASM/Programs/python.o" \
    "${PIE_HACL_PRE[@]}" \
    "$BUILD_WASM/Modules/expat/libexpat.a" \
    "${PIE_HACL_MID[@]}" \
    "$BUILD_WASM/Modules/_decimal/libmpdec/libmpdec.a" \
    "${PIE_HACL_POST[@]}" \
    "$SYSROOT/lib/wasm32-wasi/set_stack_pointer.o" \
    "$SYSROOT/lib/wasm32-wasi/crt1_shared.o" \
    "$SYSROOT/lib/wasm32-wasi/lind_utils.o" \
    -ldl -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -lpthread -lm

  if [[ ! -f "$PYTHON_WASM" ]]; then
    echo "[cpython] ERROR: PIE python binary not produced." >&2
    exit 1
  fi

  echo "[cpython] running wasm-opt on PIE python..."
  "$WASM_OPT" \
    --enable-bulk-memory --enable-threads \
    --epoch-injection --pass-arg=epoch-import --pass-arg=epoch-main-module \
    --asyncify --pass-arg=asyncify-import-globals \
    --debuginfo \
    "$PYTHON_WASM" -o "$PYTHON_OPT_WASM" \
    || { echo "[cpython] ERROR: wasm-opt failed on PIE python" >&2; exit 1; }

  if [[ ! -f "$PYTHON_OPT_WASM" ]]; then
    echo "[cpython] ERROR: Failed to generate $PYTHON_OPT_WASM" >&2
    exit 1
  fi

  echo "[cpython] adding dylink exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __stack_pointer global __stack_pointer

  if [[ -x "$LIND_BOOT" ]]; then
    echo "[cpython] generating cwasm via lind-boot --precompile..."
    if "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM"; then
      if [[ -f "$PYTHON_OPT_CWASM" ]]; then
        cp "$PYTHON_OPT_CWASM" "$PYTHON_OUT_DIR/usr/local/bin/python"
        echo "[cpython] python staged as $PYTHON_OUT_DIR/usr/local/bin/python"
      else
        echo "[cpython] ERROR: No .cwasm binary generated." >&2
        exit 1
      fi
    else
      echo "[cpython] ERROR: lind-boot --precompile failed." >&2
      exit 1
    fi
  else
    echo "[cpython] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
    exit 1
  fi
fi

popd >/dev/null

echo
echo "[cpython] build complete. Outputs under:"
echo "  $PYTHON_OUT_DIR"
ls -lh "$PYTHON_OUT_DIR" || true
