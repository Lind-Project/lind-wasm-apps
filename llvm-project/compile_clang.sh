#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Clang/LLD WASI build helper for lind-wasm-apps
#
# Cross-compiles LLVM 18.1.8 (clang + lld) to wasm32-wasi so that the
# compiler and linker can run inside the Lind sandbox.  The resulting tools
# target x86_64-unknown-linux-gnu (X86 backend only).
#
# High-level strategy:
#   1. Build native LLVM tools (llvm-tblgen, clang-tblgen, etc.) — required
#      because CMake can't run wasm binaries during the build
#   2. Generate CMake toolchain file for wasm32-wasi cross-compilation
#   3. Configure cross-build with CMake
#   4. Build clang and lld
#   5. Post-process each binary: wasm-opt (asyncify) + lind-boot (precompile)
#
# Based on Alice's work on the alice-clang branch in lind-wasm.
#
# Prerequisites:
#   - Run 'make preflight' and ensure libc++ is in the merged sysroot
#     (run 'make libcxx merge-sysroot' or let the Makefile handle it)
#   - cmake >= 3.20 and ninja (or make) must be on PATH
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLVM_SRC="$SCRIPT_DIR/llvm"

APPS_BUILD="$APPS_ROOT/build"
MERGED_SYSROOT="$APPS_BUILD/sysroot_merged"
STAGE_DIR="$APPS_BUILD/clang/usr/local/bin"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
fi

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
LIND_DYLINK="${LIND_DYLINK:-0}"

# In dylink mode clang's own executable becomes a wasm PIE that imports
# libc++/libc++abi at runtime (via --preload) instead of statically embedding
# them — mirrors bash/compile_bash.sh's DYLINK branch. LLVM/clang's own ~70
# component libraries stay statically embedded either way (not attempting
# LLVM_LINK_LLVM_DYLIB/CLANG_LINK_CLANG_DYLIB here — that uses CMake's native
# -shared machinery, which doesn't speak lind's wasm-dylink ABI).
if [[ "$LIND_DYLINK" == "1" ]]; then
  EXTRA_CFLAGS="-fPIC"
  EXTRA_CXXFLAGS="-fPIC"
  EXE_LINKER_EXTRA="-nostdlib++ -Wl,-pie -Wl,--import-table -Wl,--allow-undefined -Wl,--unresolved-symbols=import-dynamic -Wl,--export=__wasm_call_ctors -Wl,--export-if-defined=__wasm_init_tls -Wl,--export=__tls_base $LIND_WASM_ROOT/src/glibc/build/lind_debug.o"
  LLVM_ENABLE_PIC_FLAG="ON"
  CXX_STANDARD_LIBS="-lc -lcompiler_rt"
else
  EXTRA_CFLAGS=""
  EXTRA_CXXFLAGS=""
  EXE_LINKER_EXTRA=""
  LLVM_ENABLE_PIC_FLAG="OFF"
  CXX_STANDARD_LIBS="-lc++ -lc++abi -lc -lcompiler_rt"
fi

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
CMAKE="${CMAKE:-cmake}"

# ----------------------------------------------------------------------
# 1) Load toolchain from Makefile preflight
# ----------------------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
else
  echo "[clang] ERROR: missing toolchain env '$TOOL_ENV' (run 'make preflight' first)" >&2
  exit 1
fi

: "${CLANG:?missing CLANG in $TOOL_ENV}"
: "${AR:?missing AR in $TOOL_ENV}"
: "${RANLIB:?missing RANLIB in $TOOL_ENV}"
: "${NM:?missing NM in $TOOL_ENV}"

LLVM_BIN_DIR="$(dirname "$CLANG")"
CLANGXX="$LLVM_BIN_DIR/clang++"
if [[ ! -x "$CLANGXX" ]]; then
  echo "[clang] WARN: clang++ not found; creating symlink to clang"
  ln -sf "$CLANG" "$CLANGXX"
fi

# Sanity checks
if [[ ! -d "$LLVM_SRC" ]]; then
  echo "[clang] ERROR: LLVM source dir not found at '$LLVM_SRC'" >&2
  exit 1
fi
if [[ ! -d "$SCRIPT_DIR/clang" ]]; then
  echo "[clang] ERROR: clang source dir not found at '$SCRIPT_DIR/clang'" >&2
  exit 1
fi
if [[ ! -d "$MERGED_SYSROOT" ]]; then
  echo "[clang] ERROR: merged sysroot '$MERGED_SYSROOT' not found. Run 'make merge-sysroot' first." >&2
  exit 1
fi
if [[ ! -f "$MERGED_SYSROOT/lib/wasm32-wasi/libc++.a" ]]; then
  echo "[clang] ERROR: libc++.a not found in merged sysroot. Run 'make libcxx merge-sysroot' first." >&2
  exit 1
fi
if ! command -v "$CMAKE" &>/dev/null; then
  echo "[clang] ERROR: cmake not found on PATH" >&2
  exit 1
fi

mkdir -p "$STAGE_DIR"

LIBCXX_INCLUDE="$MERGED_SYSROOT/include/wasm32-wasi/c++/v1"

echo "[clang] using CLANG          = $CLANG"
echo "[clang] using CLANGXX        = $CLANGXX"
echo "[clang] using AR             = $AR"
echo "[clang] using LD             = $LD"
echo "[clang] LIND_WASM_ROOT       = $LIND_WASM_ROOT"
echo "[clang] merged sysroot       = $MERGED_SYSROOT"
echo "[clang] libc++ headers       = $LIBCXX_INCLUDE"
echo "[clang] stage dir            = $STAGE_DIR"
echo

# ----------------------------------------------------------------------
# 2) Build native LLVM tools (tablegen etc.)
#
# CMake cannot run wasm binaries during the build, so we need native
# versions of llvm-tblgen, clang-tblgen, llvm-min-tblgen, and
# clang-tidy-confusable-chars-gen for the cross-build.
# ----------------------------------------------------------------------
NATIVE_BUILD="$APPS_BUILD/llvm-native-build"

if [[ ! -x "$NATIVE_BUILD/bin/llvm-tblgen" ]] || \
   [[ ! -x "$NATIVE_BUILD/bin/clang-tblgen" ]]; then
  echo "[clang] building native LLVM tools (tablegen etc.)…"
  mkdir -p "$NATIVE_BUILD"

  "$CMAKE" -B "$NATIVE_BUILD" -S "$LLVM_SRC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_TARGETS_TO_BUILD="X86"

  "$CMAKE" --build "$NATIVE_BUILD" --target \
    llvm-tblgen clang-tblgen llvm-min-tblgen \
    -j"$JOBS"

  echo "[clang] native tools built at $NATIVE_BUILD/bin/"
else
  echo "[clang] native LLVM tools already built; skipping."
fi

# ----------------------------------------------------------------------
# 3) Build compiler-rt
# ----------------------------------------------------------------------
echo "[clang] building compiler-rt…"

"$SCRIPT_DIR/compile_compiler-rt.sh"

# The cross-build's CMAKE_EXE_LINKER_FLAGS only searches $MERGED_SYSROOT (not
# the overlay compile_compiler-rt.sh writes to), and CMAKE_C/CXX_STANDARD_LIBRARIES
# below links "-lcompiler_rt" while LLVM's build produces libclang_rt.builtins-*.a —
# merge the overlay in and alias the name so the link step can find it.
mkdir -p "$MERGED_SYSROOT/lib/wasm32-wasi"
rsync -a "$APPS_BUILD/sysroot_overlay/usr/lib/wasm32-wasi/" "$MERGED_SYSROOT/lib/wasm32-wasi/"
if [[ ! -f "$MERGED_SYSROOT/lib/wasm32-wasi/libcompiler_rt.a" ]]; then
  cp "$MERGED_SYSROOT/lib/wasm32-wasi/libclang_rt.builtins-wasm32.a" "$MERGED_SYSROOT/lib/wasm32-wasi/libcompiler_rt.a"
fi

# ----------------------------------------------------------------------
# 4) Generate CMake toolchain file for wasm32-wasi cross-compilation
# ----------------------------------------------------------------------
CROSS_BUILD="$APPS_BUILD/llvm-cross-build"
BUILD_DIR="$CROSS_BUILD"
mkdir -p "$BUILD_DIR"

TOOLCHAIN_FILE="$BUILD_DIR/Toolchain-WASI-LLVM.cmake"
sed -e "s|@CLANG@|$CLANG|g" \
    -e "s|@CLANGXX@|$CLANGXX|g" \
    -e "s|@AR@|$AR|g" \
    -e "s|@NM@|$NM|g" \
    -e "s|@LD@|$LD|g" \
    -e "s|@RANLIB@|$RANLIB|g" \
    -e "s|@BASE_SYSROOT@|$BASE_SYSROOT|g" \
    -e "s|@LIBCXX_INCLUDE@|$LIBCXX_INCLUDE|g" \
    -e "s|@MERGED_SYSROOT@|$MERGED_SYSROOT|g" \
    -e "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" \
    -e "s|@EXTRA_CFLAGS@|$EXTRA_CFLAGS|g" \
    -e "s|@EXTRA_CXXFLAGS@|$EXTRA_CXXFLAGS|g" \
    -e "s|@EXE_LINKER_EXTRA@|$EXE_LINKER_EXTRA|g" \
    "$SCRIPT_DIR/Toolchain-WASI-LLVM.cmake.in" > "$TOOLCHAIN_FILE"

echo "[clang] generated toolchain file: $TOOLCHAIN_FILE"

# ----------------------------------------------------------------------
# 5) Configure cross-build
# ----------------------------------------------------------------------
echo "[clang] configuring cross-build…"

"$CMAKE" -B "$CROSS_BUILD" -S "$LLVM_SRC" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_INSTALL_PREFIX="$CROSS_BUILD/install" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS="clang;lld" \
  -DLLVM_HOST_TRIPLE="wasm32-unknown-wasi" \
  -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-unknown-linux-gnu" \
  -DLLVM_TARGETS_TO_BUILD="X86" \
  -DLLVM_NATIVE_TOOL_DIR="$NATIVE_BUILD/bin" \
  -DLLVM_ENABLE_THREADS=OFF \
  -DLLVM_ENABLE_PIC=$LLVM_ENABLE_PIC_FLAG \
  -DLLVM_ENABLE_LIBCXX=ON \
  -DLLVM_BUILD_SHARED_LIBS=OFF \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_GOOGLETEST=OFF \
  -DLLVM_TOOL_CLANG_BUILD=ON \
  -DLLVM_TOOL_LLD_BUILD=ON \
  -DLLVM_TOOL_LLI_BUILD=OFF \
  -DLLVM_TOOL_LLVM_JITLINK_EXECUTOR_BUILD=OFF \
  -DLLD_ENABLE_TARGETS="ELF" \
  -DCLANG_INCLUDE_TESTS=OFF \
  -DLLD_INCLUDE_TESTS=OFF \
  -DCMAKE_SKIP_RPATH=ON \
  -DCMAKE_SKIP_INSTALL_RPATH=ON \
  -DCMAKE_C_STANDARD_LIBRARIES="-lc -lcompiler_rt" \
  -DCMAKE_CXX_STANDARD_LIBRARIES="$CXX_STANDARD_LIBS" \
  -DHAVE_LIBRT=0 \
  -DHAVE_LIBATOMIC=1 \
  -DHAVE_CXX_ATOMICS_WITHOUT_LIB=ON \
  -DHAVE_CXX_ATOMICS64_WITHOUT_LIB=ON \
  -DHAVE_CXX_ATOMICS_WITH_LIB=OFF \
  -DHAVE_CXX_ATOMICS64_WITH_LIB=OFF

# ----------------------------------------------------------------------
# 6) Build clang and lld
# ----------------------------------------------------------------------
echo "[clang] building clang…"
"$CMAKE" --build "$CROSS_BUILD" --target clang -j"$JOBS"

echo "[clang] building lld…"
"$CMAKE" --build "$CROSS_BUILD" --target lld -j"$JOBS"

echo "[clang] installing core resource headers…"
"$CMAKE" --build "$CROSS_BUILD" --target install-core-resource-headers -j"$JOBS"

# ----------------------------------------------------------------------
# 7) Post-processing helper
# ----------------------------------------------------------------------
post_process_binary() {
  local NAME="$1"
  local SRC_BIN="$2"
  local USE_OS="${3:-false}"  # use -Os instead of -O2

  if [[ ! -f "$SRC_BIN" ]]; then
    echo "[clang] ERROR: $NAME binary not produced at '$SRC_BIN'" >&2
    return 1
  fi

  local WASM_FILE="$SCRIPT_DIR/${NAME}.wasm"
  local OPT_WASM="$SCRIPT_DIR/${NAME}.opt.wasm"
  cp "$SRC_BIN" "$WASM_FILE"
  echo "[clang] $NAME binary size: $(du -h "$WASM_FILE" | cut -f1)"

  # --- wasm-opt ---
  if [[ ! -x "$WASM_OPT" ]]; then
    echo "[clang] ERROR: wasm-opt not found at '$WASM_OPT'; exiting." >&2
    exit 1
  fi

  local OPT_FLAGS=()
  if [[ "$USE_OS" == "true" ]]; then
    OPT_FLAGS+=(-Os)
  else
    OPT_FLAGS+=(-O2)
  fi

  # Build asyncify removelist for this binary
  local ASYNCIFY_IGNORE="$SCRIPT_DIR/${NAME}_asyncify_ignore.txt"
  generate_asyncify_ignorelist "$NAME" "$ASYNCIFY_IGNORE"
  local IGNORE_COUNT
  IGNORE_COUNT=$(wc -l < "$ASYNCIFY_IGNORE")
  echo "[clang] asyncify removelist for $NAME: $IGNORE_COUNT wildcard patterns"

  echo "[clang] running wasm-opt on $NAME (epoch-injection + asyncify + ${OPT_FLAGS[*]})…"
  "$WASM_OPT" --epoch-injection --asyncify \
    --pass-arg=asyncify-removelist@@"$ASYNCIFY_IGNORE" \
    --debuginfo "${OPT_FLAGS[@]}" \
    "$WASM_FILE" -o "$OPT_WASM"

  if [[ ! -f "$OPT_WASM" ]]; then
    echo "[clang] ERROR: failed to generate '$OPT_WASM'; exiting." >&2
    exit 1
  fi

  # --- lind-boot --precompile ---
  if [[ ! -x "$LIND_BOOT" ]]; then
    echo "[clang] ERROR: lind-boot not found at '$LIND_BOOT'" >&2
    exit 1
  fi

  echo "[clang] generating cwasm for $NAME via lind-boot --precompile…"
  "$LIND_BOOT" --precompile "$OPT_WASM"

  local OPT_CWASM="$SCRIPT_DIR/${NAME}.opt.cwasm"
  if [[ ! -f "$OPT_CWASM" ]]; then
    echo "[clang] ERROR: precompile produced no .cwasm for $NAME" >&2
    exit 1
  fi

  cp "$OPT_CWASM" "$STAGE_DIR/$NAME"
  echo "[clang] $NAME staged as $STAGE_DIR/$NAME (precompiled)"
}

# ----------------------------------------------------------------------
# 8) Asyncify ignore list generator
#
# Like GCC's cc1, clang is a massive C++ binary with auto-generated
# code (TableGen instruction selection, pattern matchers) and
# template-heavy libraries that explode under asyncify.  These are
# all pure computation with no I/O or yield points.
# ----------------------------------------------------------------------
generate_asyncify_ignorelist() {
  local NAME="$1"
  local OUTFILE="$2"

  # The WASM name section contains a mix of demangled C++ names and
  # mangled _Z* names.  All C++ functions in clang/LLVM are pure
  # computation — I/O only happens through C runtime functions (glibc
  # wrappers like __lind_make_syscall, read, write, etc.) which don't
  # have C++ mangled names.
  #
  # Exclude ALL C++ functions from asyncify.  This is safe because:
  #   - Asyncify only needs to instrument functions that transitively
  #     reach yield points (I/O syscalls)
  #   - All yield points go through C runtime stubs (no _Z prefix,
  #     no C++ demangled names with ::)
  #   - The C stubs are small and asyncify handles them fine
  #
  # We match both mangled (_Z*) and demangled (*::*) C++ names,
  # plus common LLVM/Clang class names as a safety net.
  cat > "$OUTFILE" << 'PATTERNS'
_Z*
*::*
*(anonymous namespace)*
PATTERNS
}

# ----------------------------------------------------------------------
# 9) Locate and post-process binaries
# ----------------------------------------------------------------------
# clang binary — CMake produces bin/clang-18.wasm (or similar)
CLANG_BIN=""
for candidate in \
  "$CROSS_BUILD/bin/clang-18.wasm" \
  "$CROSS_BUILD/bin/clang-18" \
  "$CROSS_BUILD/bin/clang.wasm" \
  "$CROSS_BUILD/bin/clang"; do
  if [[ -f "$candidate" ]]; then
    CLANG_BIN="$candidate"
    break
  fi
done

if [[ -z "$CLANG_BIN" ]]; then
  echo "[clang] ERROR: clang binary not found in $CROSS_BUILD/bin/" >&2
  echo "[clang] Contents of $CROSS_BUILD/bin/:"
  ls -la "$CROSS_BUILD/bin/" || true
  exit 1
fi

# lld binary
LLD_BIN=""
for candidate in \
  "$CROSS_BUILD/bin/lld.wasm" \
  "$CROSS_BUILD/bin/lld"; do
  if [[ -f "$candidate" ]]; then
    LLD_BIN="$candidate"
    break
  fi
done

if [[ -z "$LLD_BIN" ]]; then
  echo "[clang] ERROR: lld binary not found in $CROSS_BUILD/bin/" >&2
  echo "[clang] Contents of $CROSS_BUILD/bin/:"
  ls -la "$CROSS_BUILD/bin/" || true
  exit 1
fi

echo "[clang] found clang at: $CLANG_BIN"
echo "[clang] found lld at:   $LLD_BIN"

# clang is enormous — use -Os like GCC's cc1
post_process_binary "clang" "$CLANG_BIN" "true"
# lld is smaller — -Os is still safer
post_process_binary "lld"   "$LLD_BIN"   "true"

echo
echo "[clang] build complete. Outputs under:"
echo "  $STAGE_DIR"
ls -lh "$STAGE_DIR" || true
