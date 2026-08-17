#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Cross-compile OpenBLAS as a library for wasm32-wasi (LindWasm), and
# cross-compile its own utest/ suite so run_tests.sh can execute it.
#
# LIND_DYLINK=1 (default) is the primary, supported configuration: builds
# libopenblas.so (a dylink shared module, same recipe as zlib/openssl) as
# the consumable artifact, and links openblas_utest/openblas_utest_ext as
# dylink *executables* that import their BLAS/CBLAS symbols from
# libopenblas.so at runtime via --preload — i.e. the tests genuinely
# exercise the .so, not a separate statically-linked copy of the same code.
# LIND_DYLINK=0 is a legacy static-only fallback: libopenblas.a only, test
# binaries statically linked against it, no .so produced.
#
# Scope:
#   - BLAS + CBLAS only. LAPACK is disabled (NO_LAPACK=1, NOFORTRAN=1) because
#     LAPACK is implemented in Fortran and there is no wasm32 Fortran compiler
#     in the lind-wasm toolchain.
#   - Single-threaded (USE_THREAD=0, USE_OPENMP=0), matching how other
#     vendored libraries (zlib, openssl) run under lind-wasm's cooperative
#     scheduling model.
#   - TARGET=RISCV64_GENERIC is used as the "portable C, no assembly kernels"
#     target family (BLAS kernels for RISCV64_GENERIC are plain C, unlike the
#     bare "GENERIC" target which drags in host-architecture assumptions).
#     BINARY=32 matches wasm32's 32-bit pointer size.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${LIND_WASM_ROOT:=${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)/lind-wasm}}"

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
LLVM_BIN="${LLVM_BIN:-$(ls -d "$LIND_WASM_ROOT"/clang+llvm-*/bin 2>/dev/null | head -n1)}"

if [[ -z "${LLVM_BIN}" || ! -x "$LLVM_BIN/clang" ]]; then
  echo "[openblas] ERROR: LLVM not found under $LIND_WASM_ROOT" >&2; exit 1
fi
if [[ ! -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]]; then
  echo "[openblas] ERROR: sysroot headers missing at $BASE_SYSROOT" >&2; exit 1
fi

LIND_DYLINK="${LIND_DYLINK:-1}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# lind-wasm's runtime unconditionally requires the main module to import a
# *shared* linear memory (see lind-multi-process/src/lib.rs), even for
# single-threaded apps like this one. -pthread at link time is what makes
# wasm-ld emit --shared-memory; every other executable app in this repo
# (grep, tinycc, nginx, git, ...) carries it for the same reason, even
# though OpenBLAS itself never spawns a thread (USE_THREAD=0 below).
CC_WASI="$LLVM_BIN/clang --target=wasm32-unknown-wasi --sysroot=$BASE_SYSROOT -pthread -matomics -mbulk-memory"

# ctest.h's assertion-failure path uses real setjmp/longjmp (ctest_main()
# setjmp()s once per test, ASSERT_* longjmp()s back out on failure). This
# glibc port's setjmp/longjmp only works when the *calling* code is compiled
# with these flags — they make clang rewrite each call site into wasm
# try/catch + saveSetjmp/__wasm_longjmp (see setjmp/wasm_eh_setjmp.c).
# Without them, longjmp() unconditionally throws a wasm exception (see
# setjmp/longjmp.c) that nothing was compiled to catch, so it propagates
# uncaught and crashes the whole binary — this is what lind_compile's own
# default dynamic/static builds always add, and what compile_openblas.sh was
# previously missing entirely.
SJLJ_FLAGS="-fwasm-exceptions -mllvm -wasm-enable-sjlj"

AR="$LLVM_BIN/llvm-ar"
RANLIB="$LLVM_BIN/llvm-ranlib"
NM="$LLVM_BIN/llvm-nm"

LIND_WASM_OPT="${LIND_WASM_OPT:-$LIND_WASM_ROOT/scripts/bin/lind-wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"

OVERLAY="$REPO_ROOT/build/sysroot_overlay"
STAGE_DIR="$REPO_ROOT/build/openblas/usr/local/bin"
mkdir -p "$OVERLAY/usr/lib/wasm32-wasi" "$OVERLAY/usr/include" "$STAGE_DIR"

OPENBLAS_SRC="$REPO_ROOT/openblas"
cd "$OPENBLAS_SRC"

# ---------------------------------------------------------------------------
# One-time source patch: OpenBLAS's RISCV64_GENERIC target hardcodes
# -march=rv64imafdc -mabi=lp64d, which our wasm32 clang does not understand.
# These flags are plain '=' assignments inside ifeq($(TARGET),RISCV64_GENERIC)
# blocks (not '+='), so they cannot be cleared via a make command-line
# override without also discarding unrelated appends elsewhere in the same
# variables. Patch them out directly; idempotent (checks before editing).
# ---------------------------------------------------------------------------
if grep -q 'march=rv64imafdc -mabi=lp64d' Makefile.riscv64 2>/dev/null; then
  echo "[openblas] patching Makefile.riscv64 (removing riscv -march/-mabi for RISCV64_GENERIC)"
  sed -i '/ifeq ($(CORE), RISCV64_GENERIC)/,/endif/{/march=rv64imafdc -mabi=lp64d/d}' Makefile.riscv64
fi
if grep -q 'TARGET_FLAGS = -march=rv64imafdc -mabi=lp64d' Makefile.prebuild 2>/dev/null; then
  echo "[openblas] patching Makefile.prebuild (removing riscv -march/-mabi for RISCV64_GENERIC)"
  sed -i '/ifeq ($(TARGET), RISCV64_GENERIC)/,/endif/{/TARGET_FLAGS = -march=rv64imafdc -mabi=lp64d/d}' Makefile.prebuild
fi

# ctest.c (used by c_check to classify OS/ARCH from compiler predefines) has
# no branch for wasm32-wasi, so OSNAME/ARCH come back empty and the build
# fails downstream. Upstream OpenBLAS already carries an Emscripten branch
# that maps wasm to ARCH_RISCV64 + OS_WINDOWS (the same TARGET family we use,
# and the OS category with the fewest POSIX-threading assumptions); mirror it
# for our __wasi__ wasm32 target.
if ! grep -q '__wasi__' ctest.c 2>/dev/null; then
  echo "[openblas] patching ctest.c (adding wasm32-wasi OS/ARCH detection)"
  cat >> ctest.c <<'EOF'

#if defined(__wasi__) || (defined(__wasm32__) && !defined(__EMSCRIPTEN__))
ARCH_RISCV64
OS_WINDOWS
#endif
EOF
fi

echo "[openblas] CC=$CC_WASI"

make clean >/dev/null 2>&1 || true

# Branch CFLAGS based on Dylink mode, same as zlib/openssl: PIC objects are
# needed both to statically link and to later wrap the whole archive into a
# dylink .so via --experimental-pic.
if [[ "$LIND_DYLINK" == "1" ]]; then
  echo "[openblas] Building with PIC and default visibility for Dynamic Linking..."
  OPENBLAS_CFLAGS="-O2 -g -fPIC -fvisibility=default"
else
  echo "[openblas] Building standard static objects for Static Linking..."
  OPENBLAS_CFLAGS="-O2 -g"
fi

# CROSS=1 additionally suppresses OpenBLAS's own "build then execute" test
# steps (utest/ctest run_test rules) that the default 'all' target would
# otherwise try to run on the host — which fails, since these binaries are
# wasm32 and cannot run there. We build utest/ctest here (binaries only,
# not executed) so run_tests.sh can run them for real under lind-wasm.
OPENBLAS_MAKE_ARGS=(
  CC="$CC_WASI"
  HOSTCC=cc
  FC=false
  AR="$AR"
  RANLIB="$RANLIB"
  NM="$NM"
  TARGET=RISCV64_GENERIC
  BINARY=32
  CROSS=1
  NOFORTRAN=1
  NO_LAPACK=1
  NO_LAPACKE=1
  USE_THREAD=0
  USE_OPENMP=0
  NO_SHARED=1
  NEED_PIC=0
  FIXED_LIBNAME=1
  BUILD_SINGLE=1
  BUILD_DOUBLE=1
  BUILD_COMPLEX=0
  BUILD_COMPLEX16=0
  BUILD_BFLOAT16=0
  CFLAGS="$OPENBLAS_CFLAGS"
  LDFLAGS="-Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
)

make -j"$JOBS" "${OPENBLAS_MAKE_ARGS[@]}" libs netlib \
  || { echo "[openblas] ERROR: library build failed" >&2; exit 1; }

if [[ ! -f "$OPENBLAS_SRC/libopenblas.a" ]]; then
  echo "[openblas] ERROR: libopenblas.a was not produced" >&2
  exit 1
fi

cp "$OPENBLAS_SRC/libopenblas.a" "$OVERLAY/usr/lib/wasm32-wasi/libopenblas.a"
"$RANLIB" "$OVERLAY/usr/lib/wasm32-wasi/libopenblas.a"
mkdir -p "$OVERLAY/usr/include/openblas"
cp "$OPENBLAS_SRC"/*.h "$OVERLAY/usr/include/openblas/" 2>/dev/null || true
cp "$OPENBLAS_SRC/cblas.h" "$OVERLAY/usr/include/" 2>/dev/null || true
cp "$OPENBLAS_SRC/openblas_config.h" "$OVERLAY/usr/include/" 2>/dev/null || true

echo "[openblas] library done -> $OVERLAY/usr/lib/wasm32-wasi/libopenblas.a"

# ---------------------------------------------------------------------------
# Dynamic linking: wrap the whole static archive into one dylink .so, same
# recipe as zlib/openssl (--whole-archive into a single shared wasm module,
# export TLS/global-reloc entry points + __stack_pointer via add-export-tool,
# then epoch-injection + asyncify + precompile).
# ---------------------------------------------------------------------------
if [[ "$LIND_DYLINK" == "1" ]]; then
  mkdir -p "$OVERLAY/lib"
  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  LIND_COMPILE="$LIND_WASM_ROOT/scripts/bin/lind_compile"

  STATIC_LIB="$OVERLAY/usr/lib/wasm32-wasi/libopenblas.a"
  DYNAMIC_LIB_WASM="$OVERLAY/usr/lib/wasm32-wasi/libopenblas.wasm"
  DYNAMIC_LIB_OPT="$OVERLAY/usr/lib/wasm32-wasi/libopenblas.opt.wasm"
  DYNAMIC_LIB_OPT_CWASM="$OVERLAY/usr/lib/wasm32-wasi/libopenblas.opt.cwasm"
  DYNAMIC_STAGED_LIB="$OVERLAY/lib/libopenblas.so"

  "$LLVM_BIN/clang" \
      --target=wasm32-unknown-wasi \
      -fPIC \
      --sysroot "$BASE_SYSROOT" \
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
      "$LIND_WASM_ROOT/src/glibc/build/lind_debug.o" \
      -g -O0 -o "$DYNAMIC_LIB_WASM" || { echo "[openblas] ERROR: clang compilation failed" >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_WASM" ]]; then
    echo "[openblas] ERROR: Failed to generate '$DYNAMIC_LIB_WASM'; Exiting.." >&2
    exit 1
  fi

  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional || { echo "[openblas] ERROR: add-export-tool tls failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional || { echo "[openblas] ERROR: add-export-tool global failed" >&2; exit 1; }
  "$ADD_EXPORT_TOOL" "$DYNAMIC_LIB_WASM" "$DYNAMIC_LIB_WASM" __stack_pointer global __stack_pointer optional || { echo "[openblas] ERROR: add-export-tool stack pointer failed" >&2; exit 1; }

  "$LIND_WASM_OPT" --target=library "$DYNAMIC_LIB_WASM" -o "$DYNAMIC_LIB_OPT" || { echo "[openblas] ERROR: lind-wasm-opt failed on '$DYNAMIC_LIB_OPT'; Exiting.." >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT" ]]; then
    echo "[openblas] ERROR: Failed to generate '$DYNAMIC_LIB_OPT'; Exiting.." >&2
    exit 1
  fi

  "$LIND_COMPILE" --precompile-only "$DYNAMIC_LIB_OPT" || { echo "[openblas] ERROR: lind_compile failed on '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2; exit 1; }

  if [[ ! -f "$DYNAMIC_LIB_OPT_CWASM" ]]; then
    echo "[openblas] ERROR: Failed to generate '$DYNAMIC_LIB_OPT_CWASM'; Exiting.." >&2
    exit 1
  fi

  cp "$DYNAMIC_LIB_OPT_CWASM" "$DYNAMIC_STAGED_LIB"
  echo "[openblas] Dynamic shared library staged as $DYNAMIC_STAGED_LIB"
fi

# ---------------------------------------------------------------------------
# OpenBLAS's utest/ uses ctest.h's default test-discovery mechanism: each
# CTEST(suite, test) macro places a small pointer pair in a ".ctest"-named
# section, and ctest_main() walks outward from one known anchor comparing a
# magic marker to find where that section starts and ends. This assumes the
# linker concatenates every input file's contribution to the section
# contiguously — true for GNU ld by default, but NOT for wasm-ld:
#   1. wasm-ld runs --gc-sections by default, and clang's
#      __attribute__((used)) does not survive that for wasm (verified with
#      --print-gc-sections: every non-anchor file's ".ctest" contribution is
#      reported "removing unused section ...(.ctest)").
#   2. Even force-retaining specific test symbols via -Wl,--undefined=<sym>
#      does not fix discovery — this build enables bulk-memory/shared-memory
#      (see -pthread above), which makes wasm-ld emit passive data segments,
#      and the neighbor-scan's fixed pointer-stride assumption does not
#      survive whatever order/placement wasm-ld gives multiple independently
#      retained passive segments.
# Net effect: only the one test compiled into the same translation unit as
# ctest_main()'s caller (main(), in utest_main.c) was ever found — every
# other file's tests were silently invisible. Confirmed against a native
# x86_64 build of this exact source with matching flags (NOFORTRAN=1
# NO_LAPACK=1 USE_THREAD=0): openblas_utest finds 66 tests and
# openblas_utest_ext finds 600, all passing — so "0 tests" under wasm was a
# genuine discovery bug, not expected behavior for this suite.
#
# Fix: switch ctest.h to its own built-in CTEST_ADD_TESTS_MANUALLY mode,
# which bypasses the section-scan entirely in favor of explicit
# __ctest_addTest(&test) calls, then auto-generate those calls from the
# *compiled objects themselves* (llvm-nm), not by regexing the .c source:
# several test files are compiled multiple times with different -D flags to
# produce different type variants (e.g. test_axpy.c without -DCOMPLEX/-DDOUBLE
# only defines the CTEST(axpy, saxpy_inc_0)/CTEST(axpy, daxpy_inc_0) symbols —
# the zaxpy/caxpy CTEST(...) invocations are also present in the raw source
# text but sit behind #ifdef COMPLEX/DOUBLE and never actually get compiled
# for that particular object). Reading the real compiled symbol table is the
# only way to know exactly which tests exist in a given .o.
# This needs one more change: CTEST_STRUCT's per-test struct is `static`
# (internal linkage) by default, which the scan trick relied on being
# invisible outside its own TU; manual registration needs to reference each
# struct's address from a separate generated file, so it must have external
# linkage instead.
# ---------------------------------------------------------------------------
if grep -q 'static struct ctest __TNAME(sname, tname)  = {' utest/ctest.h 2>/dev/null; then
  echo "[openblas] patching utest/ctest.h (external linkage for CTEST structs; needed for manual test registration)"
  sed -i 's/    static struct ctest __TNAME(sname, tname)  = {/    struct ctest __TNAME(sname, tname)  = {/' utest/ctest.h
fi

generate_ctest_registry() {
  local out="$1"; shift
  local n=0
  {
    echo "/* auto-generated by compile_openblas.sh: explicit ctest.h test registration."
    echo " * wasm-ld does not support the linker-section scan ctest.h normally uses"
    echo " * to auto-discover tests across object files; see compile_openblas.sh. */"
    echo "struct ctest;"
    echo "extern void __ctest_addTest(struct ctest *);"
    for sym in "$@"; do
      echo "extern struct ctest $sym;"
    done
    echo "__attribute__((constructor))"
    echo "static void __register_openblas_tests(void) {"
    for sym in "$@"; do
      echo "    __ctest_addTest(&$sym);"
      n=$((n + 1))
    done
    echo "}"
  } > "$out"
  echo "[openblas] $out: registered $n tests" >&2
}

# Derive the exact .o files each binary links from make itself (rather than
# hand-copying OBJS/OBJS_EXT), so this stays correct even though those
# variables are built up across several NO_LAPACK/OSNAME-conditional blocks.
# On a rebuild (utest/Makefile already patched below from a prior run, but
# the generated registry .c files removed by clean.sh), OBJS/OBJS_EXT already
# include our own registry objects — drop them here since we haven't
# (re)generated their source yet at this point.
UTEST_OBJS=$(make --no-print-directory -C utest "${OPENBLAS_MAKE_ARGS[@]}" --eval=$'__print_objs:\n\t@echo $(OBJS)' __print_objs 2>/dev/null \
  | tr ' ' '\n' | grep -vx 'test_registry\.o' | tr '\n' ' ')
UTEST_EXT_OBJS=$(make --no-print-directory -C utest "${OPENBLAS_MAKE_ARGS[@]}" --eval=$'__print_objs:\n\t@echo $(OBJS_EXT)' __print_objs 2>/dev/null \
  | tr ' ' '\n' | grep -vx 'test_extensions/test_registry_ext\.o' | tr '\n' ' ')

# Compile (but don't yet link) those objects so their real symbol tables
# exist to read from. Same CFLAGS as the final 'all' build below, so make
# won't consider them stale and won't recompile them a second time.
make -j"$JOBS" -C utest "${OPENBLAS_MAKE_ARGS[@]}" CFLAGS="$OPENBLAS_CFLAGS -DCTEST_ADD_TESTS_MANUALLY $SJLJ_FLAGS" $UTEST_OBJS $UTEST_EXT_OBJS \
  || { echo "[openblas] ERROR: utest object build failed" >&2; exit 1; }

extract_ctest_symbols() {
  for o in "$@"; do
    case "$o" in
      utest_main.o|test_extensions/xerbla.o|test_extensions/common.o) continue ;;
    esac
    "$NM" --defined-only "utest/$o" 2>/dev/null \
      | awk '$2 == "D" && $3 != "__ctest_suite_test" {print $3}'
  done
}

# shellcheck disable=SC2046
generate_ctest_registry "utest/test_registry.c" $(extract_ctest_symbols $UTEST_OBJS)
# shellcheck disable=SC2046
generate_ctest_registry "utest/test_extensions/test_registry_ext.c" $(extract_ctest_symbols $UTEST_EXT_OBJS)

if [[ "$LIND_DYLINK" != "1" ]] && ! grep -q 'test_registry.o' utest/Makefile 2>/dev/null; then
  # Only needed for the legacy static path below, which links via OpenBLAS's
  # own $(UTESTBIN)/$(UTESTEXTBIN) rules and therefore needs the registry
  # objects folded into $(OBJS)/$(OBJS_EXT). The dylink path links these
  # binaries itself and passes its object list explicitly.
  echo "[openblas] patching utest/Makefile (adding generated test registry objects)"
  sed -i '/^all : run_test/i OBJS += test_registry.o\nOBJS_EXT += $(DIR_EXT)/test_registry_ext.o\n' utest/Makefile
fi

# Always compile the two registry objects themselves now that their source
# exists (harmless no-op for the legacy static path — 'all' below will see
# them already up to date and just link).
make -j"$JOBS" -C utest "${OPENBLAS_MAKE_ARGS[@]}" CFLAGS="$OPENBLAS_CFLAGS -DCTEST_ADD_TESTS_MANUALLY $SJLJ_FLAGS" \
  test_registry.o test_extensions/test_registry_ext.o \
  || { echo "[openblas] ERROR: test registry object build failed" >&2; exit 1; }

if [[ ! -x "$LIND_WASM_OPT" ]]; then
  echo "[openblas] ERROR: lind-wasm-opt not found at '$LIND_WASM_OPT'" >&2
  exit 1
fi
if [[ ! -x "$LIND_BOOT" ]]; then
  echo "[openblas] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
  exit 1
fi

if [[ "$LIND_DYLINK" == "1" ]]; then
  # -------------------------------------------------------------------------
  # Dylink executables: link openblas_utest/openblas_utest_ext WITHOUT
  # libopenblas.a. BLAS/CBLAS symbols are left undefined and resolved as
  # wasm imports at runtime by whatever the "env" module namespace provides
  # — i.e. libopenblas.so, loaded via `lind_run --preload env=lib/libopenblas.so`
  # (see run_tests.sh). This is the same recipe every dylink *executable* in
  # this repo uses to consume a dependency .so (see git/compile_git.sh,
  # grep/compile_grep.sh): -nostartfiles + -Wl,-pie + --import-table +
  # --unresolved-symbols=import-dynamic + the crt1_shared.o/lind_utils.o CRT
  # objects, with no -l<dep> anywhere — the dependency's .so is never named
  # at link time at all, only at run time via --preload.
  # -------------------------------------------------------------------------
  ADD_EXPORT_TOOL="$LIND_WASM_ROOT/tools/add-export-tool/add-export-tool"
  DYLINK_CRT_OBJS=(
    "$BASE_SYSROOT/lib/wasm32-wasi/crt1_shared.o"
    "$BASE_SYSROOT/lib/wasm32-wasi/lind_utils.o"
  )
  for obj in "${DYLINK_CRT_OBJS[@]}"; do
    if [[ ! -f "$obj" ]]; then
      echo "[openblas] ERROR: required dylink CRT object '$obj' not found." >&2
      exit 1
    fi
  done

  LDFLAGS_DYLINK_EXE=(
    -fPIC
    -nostartfiles
    -Wl,-pie
    -Wl,--import-table
    -Wl,--import-memory
    -Wl,--export-memory
    -Wl,--shared-memory
    -Wl,--max-memory=67108864
    -Wl,--allow-undefined
    -Wl,--unresolved-symbols=import-dynamic
    -Wl,--export=__wasm_call_ctors
    -Wl,--export-if-defined=__wasm_init_tls
    -Wl,--export=__tls_base
  )

  link_dylink_utest() {
    local bin="$1"; shift
    local wasm_out="$OPENBLAS_SRC/utest/$bin"
    (
      cd utest
      # shellcheck disable=SC2086
      $CC_WASI $SJLJ_FLAGS "${LDFLAGS_DYLINK_EXE[@]}" "${DYLINK_CRT_OBJS[@]}" $* -o "$bin"
    ) || { echo "[openblas] ERROR: dylink link failed for $bin" >&2; exit 1; }

    "$ADD_EXPORT_TOOL" "$wasm_out" "$wasm_out" __wasm_apply_tls_relocs func __wasm_apply_tls_relocs optional \
      || { echo "[openblas] ERROR: add-export-tool tls failed for $bin" >&2; exit 1; }
    "$ADD_EXPORT_TOOL" "$wasm_out" "$wasm_out" __wasm_apply_global_relocs func __wasm_apply_global_relocs optional \
      || { echo "[openblas] ERROR: add-export-tool global failed for $bin" >&2; exit 1; }
    "$ADD_EXPORT_TOOL" "$wasm_out" "$wasm_out" __stack_pointer global __stack_pointer optional \
      || { echo "[openblas] ERROR: add-export-tool stack pointer failed for $bin" >&2; exit 1; }
  }

  link_dylink_utest openblas_utest $UTEST_OBJS test_registry.o
  link_dylink_utest openblas_utest_ext $UTEST_EXT_OBJS test_extensions/test_registry_ext.o

  LIND_WASM_OPT_MODE="--target=main"
else
  # ---------------------------------------------------------------------------
  # Legacy static path: OpenBLAS's own utest/Makefile rules statically link
  # $(OBJS)/$(OBJS_EXT) against ../libopenblas.a. CROSS=1 (already in
  # OPENBLAS_MAKE_ARGS) turns the 'all' target's run_test rule into a
  # build-only no-op, since these binaries can't run on the host.
  # ---------------------------------------------------------------------------
  make -C utest -j"$JOBS" "${OPENBLAS_MAKE_ARGS[@]}" CFLAGS="$OPENBLAS_CFLAGS -DCTEST_ADD_TESTS_MANUALLY $SJLJ_FLAGS" all \
    || { echo "[openblas] ERROR: utest build failed" >&2; exit 1; }

  LIND_WASM_OPT_MODE="--static"
fi

# ---------------------------------------------------------------------------
# The linked utest binaries are raw wasm32 modules; lind-wasm's runtime needs
# them instrumented (epoch injection, asyncify, and — since SJLJ_FLAGS above
# makes ctest.h's setjmp/longjmp use wasm exception-handling — conversion
# from clang's legacy EH encoding to the standard exnref-based one Cranelift
# actually supports) and precompiled to .cwasm via lind-boot before they can
# run. lind-wasm-opt (not raw wasm-opt) encodes the exact flag set and pass
# ordering this requires per target — see its source for details.
# ---------------------------------------------------------------------------
for bin in openblas_utest openblas_utest_ext; do
  src="$OPENBLAS_SRC/utest/$bin"
  if [[ ! -f "$src" ]]; then
    echo "[openblas] WARNING: $bin was not produced; skipping" >&2
    continue
  fi

  opt_wasm="$OPENBLAS_SRC/utest/$bin.opt.wasm"
  "$LIND_WASM_OPT" "$LIND_WASM_OPT_MODE" "$src" -o "$opt_wasm" \
    || { echo "[openblas] ERROR: lind-wasm-opt failed on $bin" >&2; exit 1; }

  "$LIND_BOOT" --precompile "$opt_wasm" \
    || { echo "[openblas] ERROR: lind-boot --precompile failed on $bin" >&2; exit 1; }

  opt_cwasm="$OPENBLAS_SRC/utest/$bin.opt.cwasm"
  if [[ ! -f "$opt_cwasm" ]]; then
    echo "[openblas] ERROR: $opt_cwasm was not produced" >&2
    exit 1
  fi
  cp "$opt_cwasm" "$STAGE_DIR/$bin"
  echo "[openblas] staged utest binary -> $STAGE_DIR/$bin"
done

if [[ ! -f "$STAGE_DIR/openblas_utest" ]]; then
  echo "[openblas] ERROR: openblas_utest was not produced" >&2
  exit 1
fi

echo "[openblas] done"
