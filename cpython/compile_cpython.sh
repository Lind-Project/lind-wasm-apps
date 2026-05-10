#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# CPython build helper for lind-wasm-apps
#
# Build modes (BUILD_MODE):
#   wasi   (default) — original WASI cross-compilation
#   linux            — Linux syscall mode: ac_sys_system=Linux, shared
#                      extension modules, lind-run-python wrapper,
#                      lind-specific patches applied to the CPython source
#                      tree before make and reverted after make install
#
# Dynamic linking (LIND_DYLINK=1):
#   Builds shared libpython + PIE python binary in addition to the static
#   binary.  Supported for both build modes, but linux+dylink is the primary
#   tested configuration.
#
# Usage examples:
#   make cpython                          # WASI static
#   LIND_DYLINK=1 make cpython            # WASI dynamic
#   BUILD_MODE=linux make cpython         # Linux static
#   LIND_DYLINK=1 BUILD_MODE=linux make cpython  # Linux dynamic (primary)
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_BUILD="$APPS_ROOT/build"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

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
BUILD_MODE="${BUILD_MODE:-wasi}"

FPCAST_FLAG=()
[[ "$LIND_FPCAST" == "1" ]] && FPCAST_FLAG=(--fpcast-emu)

if [[ "$BUILD_MODE" != "wasi" && "$BUILD_MODE" != "linux" ]]; then
  echo "[cpython] ERROR: unknown BUILD_MODE='$BUILD_MODE'; must be 'wasi' or 'linux'" >&2
  exit 1
fi

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

PYTHON_OUT_DIR="$APPS_BUILD/cpython"
BUILD_WASM="$SCRIPT_DIR/build-wasm"

if [[ ! -d "$SYSROOT" ]]; then
  echo "[cpython] ERROR: merged sysroot '$SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi

mkdir -p "$PYTHON_OUT_DIR"

echo "[cpython] using CLANG       = $CLANG"
echo "[cpython] LIND_WASM_ROOT    = $LIND_WASM_ROOT"
echo "[cpython] merged sysroot    = $SYSROOT"
echo "[cpython] output dir        = $PYTHON_OUT_DIR"
echo "[cpython] BUILD_MODE        = $BUILD_MODE"
echo "[cpython] LIND_DYLINK       = $LIND_DYLINK"
echo "[cpython] LIND_FPCAST       = $LIND_FPCAST"
echo

###############################################################################
# 1. Native host python (required for cross-compilation)
###############################################################################

"$SCRIPT_DIR/build_python_native.sh"

###############################################################################
# 2. Configure + build wasm python
###############################################################################

mkdir -p "$BUILD_WASM"
pushd "$BUILD_WASM" >/dev/null

if [[ ! -f "Makefile" ]]; then
  echo "[cpython] configuring ($BUILD_MODE mode)..."

  if [[ "$BUILD_MODE" == "linux" ]]; then
    # Linux mode: present as ac_sys_system=Linux so CPython enables full POSIX
    # APIs (sockets, getaddrinfo, shared extension modules, etc.).
    # The configure script supports ac_sys_system override via the
    # ac_sys_system=${ac_sys_system:-WASI} guard added to configure.
    # LINKFORSHARED carries the memory/stack exports needed by lind-boot.
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
  else
    # WASI mode: original configuration.
    # Create stub archives so configure's library checks pass for WASI.
    WASI_STUB_DIR="$SYSROOT/lib/wasm32-wasi"
    mkdir -p "$WASI_STUB_DIR"
    for lib in libwasi-emulated-getpid.a libwasi-emulated-signal.a libwasi-emulated-process-clocks.a; do
      [[ -f "$WASI_STUB_DIR/$lib" ]] || "$AR" crs "$WASI_STUB_DIR/$lib"
    done

    ../configure \
      --host=wasm32-unknown-wasi \
      --build=x86_64-unknown-linux-gnu \
      --with-build-python=../build-native/python \
      CC="$CLANG \
      -pthread \
      --target=wasm32-unknown-wasi \
      --sysroot $SYSROOT \
      -Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low \
      -D _FILE_OFFSET_BITS=64 -D __USE_LARGEFILE64 -g -O0 -fPIC" \
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
      --verbose
  fi
fi

###############################################################################
# 3. Linux-mode: apply source patches, build, revert patches
#    Patches are applied to the CPython source tree (Lib/) before make so
#    that both the compiled .pyc files and the native test runner see them.
#    They are reverted after make install to keep the source clean.
###############################################################################

PATCHES_DIR="$SCRIPT_DIR/patches"
LINUX_PATCHES=(
  "$PATCHES_DIR/lind-linux-utils.patch"
  "$PATCHES_DIR/lind-linux-os_helper.patch"
  "$PATCHES_DIR/lind-linux-run_workers.patch"
)
PATCHES_APPLIED=0

apply_linux_patches() {
  echo "[cpython] applying lind-linux source patches..."
  for patch_file in "${LINUX_PATCHES[@]}"; do
    [[ -f "$patch_file" ]] || { echo "[cpython] WARN: patch not found: $patch_file" >&2; continue; }
    patch -p1 -d "$SCRIPT_DIR/Lib" < "$patch_file"
  done
  PATCHES_APPLIED=1
}

revert_linux_patches() {
  [[ "$PATCHES_APPLIED" == "1" ]] || return 0
  echo "[cpython] reverting lind-linux source patches..."
  # Revert in reverse order to be safe with multi-hunk patches.
  for (( i=${#LINUX_PATCHES[@]}-1; i>=0; i-- )); do
    patch_file="${LINUX_PATCHES[$i]}"
    [[ -f "$patch_file" ]] || continue
    patch -R -p1 -d "$SCRIPT_DIR/Lib" < "$patch_file" || true
  done
  PATCHES_APPLIED=0
}

# Ensure patches are always reverted on exit (failure, signal, or success).
trap revert_linux_patches EXIT INT TERM

[[ "$BUILD_MODE" == "linux" ]] && apply_linux_patches

echo "[cpython] building wasm python..."
make AR="$AR" ARFLAGS="crs" &> make.log || {
  echo "[cpython] ERROR: make failed. See $BUILD_WASM/make.log" >&2
  tail -20 make.log >&2
  exit 1
}

make install DESTDIR="$PYTHON_OUT_DIR"

# Revert source patches now — installed tree already has the patched copies.
revert_linux_patches
trap - EXIT INT TERM

###############################################################################
# 3b. Linux-mode post-install: lind-run-python wrapper + extension modules
###############################################################################

if [[ "$BUILD_MODE" == "linux" ]]; then
  # Generate lind-run-python wrapper.
  # CPython's test framework calls: <HOSTRUNNER> <build-python> <test-args>
  # The wrapper discards the build-python argument and routes to the installed
  # /usr/local/bin/python inside lind's virtual filesystem.
  LIND_RUN_PYTHON="$BUILD_WASM/lind-run-python"
  FPCAST_ARG=""
  [[ "$LIND_FPCAST" == "1" ]] && FPCAST_ARG=" --enable-fpcast"

  cat > "$LIND_RUN_PYTHON" <<WRAPPER
#!/usr/bin/env bash
# Auto-generated by compile_cpython.sh — do not edit.
# Discards the build-dir python path supplied by CPython's test framework
# and routes to the installed binary inside lind's virtual filesystem.
shift
unset PYTHONPATH _PYTHON_PROJECT_BASE _PYTHON_SYSCONFIGDATA_PATH _PYTHON_HOST_PLATFORM
exec lind-wasm --preload env=/lib/libpython3.14.so${FPCAST_ARG} /usr/local/bin/python "\$@"
WRAPPER
  chmod +x "$LIND_RUN_PYTHON"

  # Patch HOSTRUNNER in build-wasm/Makefile so 'make test' works immediately.
  sed -i "s|^HOSTRUNNER=.*|HOSTRUNNER= $LIND_RUN_PYTHON|" Makefile
  sed -i "s|_PYTHON_HOSTRUNNER='[^']*'|_PYTHON_HOSTRUNNER='$LIND_RUN_PYTHON'|g" Makefile

  SYSCFG=$(find build -name '_sysconfigdata_*.py' 2>/dev/null | head -1)
  if [[ -n "$SYSCFG" ]]; then
    sed -i "s|'HOSTRUNNER': '[^']*'|'HOSTRUNNER': '$LIND_RUN_PYTHON'|" "$SYSCFG"
  fi

  echo "[cpython] HOSTRUNNER → $LIND_RUN_PYTHON"

  # Post-process extension module .so files: asyncify + precompile.
  # Each .so is a raw wasm shared lib; it must go through lind-wasm-opt
  # (asyncify + epoch injection in import mode) and lind-boot --precompile
  # before lind can dlopen it.
  DYNLOAD_DIR="$PYTHON_OUT_DIR/usr/local/lib/python3.14/lib-dynload"
  if [[ -d "$DYNLOAD_DIR" ]]; then
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
        ((n_fail++)) || true; continue
      fi

      if ! "$LIND_BOOT" --precompile "$tmp_opt" 2>/dev/null; then
        echo "[cpython]   WARN: lind-boot --precompile failed for $modname — skipping" >&2
        rm -f "$tmp_opt"; ((n_fail++)) || true; continue
      fi

      if [[ ! -f "$tmp_cwasm" ]]; then
        echo "[cpython]   WARN: no .cwasm produced for $modname — skipping" >&2
        rm -f "$tmp_opt"; ((n_fail++)) || true; continue
      fi

      mv "$tmp_cwasm" "$so"
      rm -f "$tmp_opt"
      ((n_ok++)) || true
    done
    echo "[cpython] extension modules: $n_ok precompiled, $n_fail skipped"
    [[ $n_fail -eq 0 ]] || echo "[cpython] WARN: $n_fail module(s) could not be precompiled" >&2
  fi
fi

###############################################################################
# 4. Optimize + precompile the main python binary (static path)
###############################################################################

if [[ "$LIND_DYLINK" != "1" ]]; then
  echo "[cpython] Mode: STATIC"

  if [[ "$BUILD_MODE" == "linux" ]]; then
    PYTHON_WASM="$BUILD_WASM/python"
  else
    PYTHON_WASM="$BUILD_WASM/python.wasm"
  fi
  PYTHON_OPT_WASM="$BUILD_WASM/python.opt.wasm"
  PYTHON_OPT_CWASM="$BUILD_WASM/python.opt.cwasm"

  if [[ ! -x "$LIND_WASM_OPT" ]]; then
    echo "[cpython] ERROR: lind-wasm-opt not found at '$LIND_WASM_OPT'" >&2
    exit 1
  fi

  echo "[cpython] running lind-wasm-opt (asyncify + optimization)..."
  "$LIND_WASM_OPT" --static "${FPCAST_FLAG[@]}" "$PYTHON_WASM" -o "$PYTHON_OPT_WASM"

  if [[ ! -f "$PYTHON_OPT_WASM" ]]; then
    echo "[cpython] ERROR: Failed to generate $PYTHON_OPT_WASM" >&2
    exit 1
  fi

  if [[ ! -x "$LIND_BOOT" ]]; then
    echo "[cpython] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
    exit 1
  fi

  echo "[cpython] generating cwasm via lind-boot --precompile..."
  "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM" || {
    echo "[cpython] ERROR: lind-boot --precompile failed." >&2; exit 1
  }
  [[ -f "$PYTHON_OPT_CWASM" ]] || {
    echo "[cpython] ERROR: No .cwasm binary generated." >&2; exit 1
  }

  mkdir -p "$PYTHON_OUT_DIR/usr/local/bin"
  cp "$PYTHON_OPT_CWASM" "$PYTHON_OUT_DIR/usr/local/bin/python"
  echo "[cpython] python staged as $PYTHON_OUT_DIR/usr/local/bin/python"
fi

###############################################################################
# 5. Dynamic linking: shared libpython + PIE python binary
###############################################################################

if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[cpython] Mode: DYNAMIC"

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

  # --- Build shared libpython ---
  echo "[cpython] building shared libpython..."
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

  [[ -f "$DYNAMIC_LIB_WASM" ]] || {
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'" >&2; exit 1
  }

  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs    func __wasm_apply_tls_relocs    optional \
    || { echo "[cpython] ERROR: add-export-tool tls failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional \
    || { echo "[cpython] ERROR: add-export-tool global failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __stack_pointer            global __stack_pointer            optional \
    || { echo "[cpython] ERROR: add-export-tool stack pointer failed" >&2; exit 1; }

  if [[ "$BUILD_MODE" == "linux" ]]; then
    "$LIND_WASM_OPT" --target=library "${FPCAST_FLAG[@]}" "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" \
      || { echo "[cpython] ERROR: lind-wasm-opt failed on shared libpython" >&2; exit 1; }
  else
    # WASI mode uses raw binaryen flags via lind-wasm-opt pass-through
    "$LIND_WASM_OPT" --target=library "${FPCAST_FLAG[@]}" "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" \
      || { echo "[cpython] ERROR: lind-wasm-opt failed on shared libpython" >&2; exit 1; }
  fi

  [[ -f "$DYNAMIC_LIB_OPT" ]] || {
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'" >&2; exit 1
  }

  "$LIND_BOOT" --precompile "$DYNAMIC_LIB_OPT" \
    || { echo "[cpython] ERROR: lind-boot --precompile failed for shared libpython" >&2; exit 1; }

  [[ -f "$DYNAMIC_LIB_OPT_CWASM" ]] || {
    echo "[cpython] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'" >&2; exit 1
  }

  cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
  echo "[cpython] shared libpython staged as $DYNAMIC_STAGED_LIB"

  # --- Build PIE python binary ---
  echo "[cpython] building PIE python binary..."
  PYTHON_WASM="$BUILD_WASM/python_shared.wasm"
  PYTHON_OPT_WASM="$BUILD_WASM/python_shared.opt.wasm"
  PYTHON_OPT_CWASM="$BUILD_WASM/python_shared.opt.cwasm"

  if [[ "$BUILD_MODE" == "linux" ]]; then
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
      -ldl -lpthread -lm \
      || { echo "[cpython] ERROR: PIE python compilation failed" >&2; exit 1; }
  else
    # WASI mode: must link in HACL/expat/mpdec archives and emulation libs
    # because there is no shared libpython to pull them from at load time.
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
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA2.a" \
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA1.a" \
      "$BUILD_WASM/Modules/expat/libexpat.a" \
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_MD5.a" \
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_BLAKE2.a" \
      "$BUILD_WASM/Modules/_decimal/libmpdec/libmpdec.a" \
      "$BUILD_WASM/Modules/_hacl/libHacl_HMAC.a" \
      "$BUILD_WASM/Modules/_hacl/libHacl_Hash_SHA3.a" \
      "$SYSROOT/lib/wasm32-wasi/crt1_shared.o" \
      "$SYSROOT/lib/wasm32-wasi/lind_utils.o" \
      -ldl -lwasi-emulated-signal -lwasi-emulated-getpid -lwasi-emulated-process-clocks -lpthread -lm \
      || { echo "[cpython] ERROR: PIE python compilation failed" >&2; exit 1; }
  fi

  [[ -f "$PYTHON_WASM" ]] || {
    echo "[cpython] ERROR: PIE python binary not produced." >&2; exit 1
  }

  echo "[cpython] running lind-wasm-opt on PIE python..."
  "$LIND_WASM_OPT" --target=main "${FPCAST_FLAG[@]}" "$PYTHON_WASM" -o "$PYTHON_OPT_WASM" \
    || { echo "[cpython] ERROR: lind-wasm-opt failed on PIE python" >&2; exit 1; }

  [[ -f "$PYTHON_OPT_WASM" ]] || {
    echo "[cpython] ERROR: Failed to generate $PYTHON_OPT_WASM" >&2; exit 1
  }

  echo "[cpython] adding dylink exports via add-export-tool..."
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_tls_relocs    func __wasm_apply_tls_relocs    optional
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional
  "$ADD_EXPORT_TOOL" "$PYTHON_OPT_WASM" "$PYTHON_OPT_WASM" __stack_pointer            global __stack_pointer

  echo "[cpython] generating cwasm via lind-boot --precompile..."
  "$LIND_BOOT" --precompile "$PYTHON_OPT_WASM" || {
    echo "[cpython] ERROR: lind-boot --precompile failed." >&2; exit 1
  }
  [[ -f "$PYTHON_OPT_CWASM" ]] || {
    echo "[cpython] ERROR: No .cwasm binary generated." >&2; exit 1
  }

  cp "$PYTHON_OPT_CWASM" "$PYTHON_OUT_DIR/usr/local/bin/python"
  echo "[cpython] python staged as $PYTHON_OUT_DIR/usr/local/bin/python"
fi

popd >/dev/null

echo
echo "[cpython] build complete ($BUILD_MODE mode). Outputs under:"
echo "  $PYTHON_OUT_DIR"
ls -lh "$PYTHON_OUT_DIR" || true
