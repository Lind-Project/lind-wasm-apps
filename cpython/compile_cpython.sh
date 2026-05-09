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
LIND_WASM_OPT="${LIND_WASM_OPT:-$LIND_WASM_ROOT/scripts/lind-wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
ADD_EXPORT_TOOL="${ADD_EXPORT_TOOL:-$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool}"

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
LIND_DYLINK="${LIND_DYLINK:-0}"
LIND_FPCAST="${LIND_FPCAST:-0}"

FPCAST_FLAG=()
[[ "$LIND_FPCAST" == "1" ]] && FPCAST_FLAG=(--fpcast-emu)

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
echo "[cpython] LIND_FPCAST       = $LIND_FPCAST"
echo

###############################################################################
# 1. Build native host python (needed for cross-compilation)
###############################################################################

"$SCRIPT_DIR/build_python_native.sh"

###############################################################################
# 2. Configure/build wasm python
###############################################################################

mkdir -p "$BUILD_WASM"
pushd "$BUILD_WASM" >/dev/null

# CPython uses -O0 because the build system relies on specific code generation
# behavior that breaks with optimization.

if [[ ! -f "Makefile" ]]; then
  echo "[cpython] configuring wasm build..."
  ../configure \
    --host=wasm32-unknown-wasi \
    --build=x86_64-unknown-linux-gnu \
    --with-build-python=../build-native/python \
    --with-ensurepip=no \
    CC="$CLANG \
    -pthread \
    --target=wasm32-unknown-wasi \
    --sysroot $SYSROOT \
    -Wl,--import-memory \
    -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC" \
    LDSHARED='$(CC) -shared -nostartfiles -Wl,--no-entry' \
    LINKFORSHARED="-Xlinker -export-dynamic -Wl,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low" \
    ac_sys_system=Linux \
    ac_cv_func_working_mktime=yes \
    ac_cv_func_mmap_fixed_mapped=yes \
    bash_cv_func_sigsetjmp=no \
    ac_cv_have_chflags=no \
    ax_cv_c_float_words_bigendian=no \
    ac_cv_file__dev_ptmx=no \
    ac_cv_file__dev_ptc=no \
    ac_cv_func_memfd_create=no \
    ac_cv_func_eventfd=no \
    ac_cv_func_timerfd_create=no \
    ac_cv_func_getaddrinfo=yes \
    ac_cv_buggy_getaddrinfo=no \
    ac_cv_libm_c99=yes \
    --verbose
fi

echo "[cpython] building wasm python..."
make AR="$AR" ARFLAGS="crs" &> make.log || {
  echo "[cpython] ERROR: make failed. See $BUILD_WASM/make.log" >&2
  tail -20 make.log >&2
  exit 1
}

# Install python files into staging dir
make install DESTDIR="$PYTHON_OUT_DIR"

###############################################################################
# 3. Generate lind-run-python wrapper and update HOSTRUNNER
#    CPython's test framework constructs: "<HOSTRUNNER> python <test-args>"
#    The wrapper drops the binary arg ("python") and routes to the installed
#    /usr/local/bin/python in lindfs with the correct preload/fpcast flags.
###############################################################################

LIND_RUN_PYTHON="$BUILD_WASM/lind-run-python"
FPCAST_ARG=""
[[ "$LIND_FPCAST" == "1" ]] && FPCAST_ARG=" --enable-fpcast"

cat > "$LIND_RUN_PYTHON" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by compile_cpython.sh — do not edit manually.
# Usage: lind-run-python <binary> [args...]
# <binary> is the build-dir python name supplied by CPython's test framework;
# it is discarded here and replaced with the installed lindfs path.
shift
# Strip host-path env vars set by PYTHON_FOR_BUILD that are invalid inside lind.
# These point to the native build tree and would shadow the installed lindfs layout.
unset PYTHONPATH _PYTHON_PROJECT_BASE _PYTHON_SYSCONFIGDATA_PATH _PYTHON_HOST_PLATFORM
exec lind-wasm --preload env=/lib/libpython3.14.so${FPCAST_ARG} /usr/local/bin/python "\$@"
WRAPPER
chmod +x "$LIND_RUN_PYTHON"

# Patch HOSTRUNNER in the Makefile (two occurrences: HOSTRUNNER= and _PYTHON_HOSTRUNNER=)
sed -i "s|^HOSTRUNNER=.*|HOSTRUNNER= $LIND_RUN_PYTHON|" "$BUILD_WASM/Makefile"
sed -i "s|_PYTHON_HOSTRUNNER='[^']*'|_PYTHON_HOSTRUNNER='$LIND_RUN_PYTHON'|g" "$BUILD_WASM/Makefile"

# Patch HOSTRUNNER in the sysconfigdata file (used by sysconfig.get_config_var)
SYSCFG=$(find "$BUILD_WASM/build" -name '_sysconfigdata_*.py' 2>/dev/null | head -1)
if [[ -n "$SYSCFG" ]]; then
  sed -i "s|'HOSTRUNNER': '[^']*'|'HOSTRUNNER': '$LIND_RUN_PYTHON'|" "$SYSCFG"
fi

echo "[cpython] HOSTRUNNER → $LIND_RUN_PYTHON"

###############################################################################
# 3b. Patch test framework: use randint() nonce instead of getpid()
#     getpid() in lind always returns CAGE_START_ID (1) for fresh cages, so it
#     is not a unique nonce.  CPython already does this for WASI/Emscripten;
#     extend the same guard to wasm32 (which lind reports as platform.machine()).
UTILS_PY="$INSTALL_DIR/usr/local/lib/python3.14/test/libregrtest/utils.py"
if [[ -f "$UTILS_PY" ]]; then
  sed -i 's/if support\.is_emscripten or support\.is_wasi:/if support.is_emscripten or support.is_wasi or platform.machine() == '"'"'wasm32'"'"':/' "$UTILS_PY"
  echo "[cpython] patched $UTILS_PY: wasm32 uses randint() nonce"
fi

###############################################################################
# 4. Post-process extension module .so files: asyncify + precompile
#    Each .so is a raw wasm shared lib; it must go through wasm-opt (asyncify +
#    epoch injection in import mode) and lind-boot --precompile before lind can
#    dlopen it.  The resulting .cwasm overwrites the .so in-place.
###############################################################################

DYNLOAD_DIR="$PYTHON_OUT_DIR/usr/local/lib/python3.14/lib-dynload"
echo "[cpython] post-processing extension modules in $DYNLOAD_DIR ..."

n_ok=0
n_fail=0
for so in "$DYNLOAD_DIR"/*.so; do
  [[ -f "$so" ]] || continue
  modname="$(basename "$so")"
  tmp_opt="${so%.so}.opt.wasm"
  tmp_cwasm="${so%.so}.opt.cwasm"

  if ! "$LIND_WASM_OPT" --target=library "${FPCAST_FLAG[@]}" "$so" -o "$tmp_opt" 2>/dev/null; then
    echo "[cpython]   WARN: lind-wasm-opt failed for $modname — skipping" >&2
    ((n_fail++)) || true
    continue
  fi

  if ! "$LIND_BOOT" --precompile "$tmp_opt" 2>/dev/null; then
    echo "[cpython]   WARN: lind-boot --precompile failed for $modname — skipping" >&2
    rm -f "$tmp_opt"
    ((n_fail++)) || true
    continue
  fi

  if [[ ! -f "$tmp_cwasm" ]]; then
    echo "[cpython]   WARN: no .cwasm produced for $modname — skipping" >&2
    rm -f "$tmp_opt"
    ((n_fail++)) || true
    continue
  fi

  mv "$tmp_cwasm" "$so"
  rm -f "$tmp_opt"
  ((n_ok++)) || true
done

echo "[cpython] extension modules: $n_ok precompiled, $n_fail skipped"
[[ $n_fail -eq 0 ]] || echo "[cpython] WARN: $n_fail module(s) could not be precompiled" >&2

###############################################################################
# 4. wasm-opt + precompile (static path)
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[cpython] Mode: DYNAMIC LINKING — skipping static wasm-opt/precompile"
else
  echo "[cpython] Mode: STATIC LINKING"

  PYTHON_WASM="$BUILD_WASM/python"
  PYTHON_OPT_WASM="$BUILD_WASM/python.opt.wasm"
  PYTHON_OPT_CWASM="$BUILD_WASM/python.opt.cwasm"

  if [[ -x "$LIND_WASM_OPT" ]]; then
    echo "[cpython] running lind-wasm-opt (asyncify + optimization)..."
    "$LIND_WASM_OPT" --static "${FPCAST_FLAG[@]}" "$PYTHON_WASM" -o "$PYTHON_OPT_WASM"
  else
    echo "[cpython] ERROR: lind-wasm-opt not found at '$LIND_WASM_OPT'" >&2
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
  DYNAMIC_LIB_WASM="$BUILD_WASM/libpython3.14.wasm"
  DYNAMIC_LIB_OPT="$BUILD_WASM/libpython3.14.opt.wasm"
  DYNAMIC_LIB_OPT_CWASM="$BUILD_WASM/libpython3.14.opt.cwasm"
  DYNAMIC_STAGED_LIB="$PYTHON_OUT_DIR/lib/libpython3.14.so"
  mkdir -p "$PYTHON_OUT_DIR/lib" "$PYTHON_OUT_DIR/usr/local/bin"

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

  "$LIND_WASM_OPT" --target=library "${FPCAST_FLAG[@]}" "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" \
    || { echo "[cpython] ERROR: lind-wasm-opt failed on shared libpython" >&2; exit 1; }

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
    "$SYSROOT/lib/wasm32-wasi/crt1_shared.o" \
    "$SYSROOT/lib/wasm32-wasi/lind_utils.o" \
    -ldl -lpthread -lm

  if [[ ! -f "$PYTHON_WASM" ]]; then
    echo "[cpython] ERROR: PIE python binary not produced." >&2
    exit 1
  fi

  echo "[cpython] running lind-wasm-opt on PIE python..."
  "$LIND_WASM_OPT" --target=main "${FPCAST_FLAG[@]}" "$PYTHON_WASM" -o "$PYTHON_OPT_WASM" \
    || { echo "[cpython] ERROR: lind-wasm-opt failed on PIE python" >&2; exit 1; }

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
