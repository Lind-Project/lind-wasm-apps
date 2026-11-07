# clang + lld (X86 target only), statically linked LLVM libraries
UPSTREAM_TESTS=0
NOTE="Very large binaries; the rewriter (gsfork-elf) may hit its per-tool timeout."
recipe_build() {
  mkdir -p obj && cd obj
  cmake -G "Unix Makefiles" ../llvm -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$MPK_CC" -DCMAKE_CXX_COMPILER="$MPK_CXX" \
    -DCMAKE_C_FLAGS="-g1" -DCMAKE_CXX_FLAGS="-g1" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_BUILD_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DCLANG_INCLUDE_TESTS=OFF -DLLD_INCLUDE_TESTS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF -DCLANG_PLUGIN_SUPPORT=OFF -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_TOOL_LLVM_DRIVER_BUILD=OFF -DCMAKE_SKIP_RPATH=ON
  make -j"$JOBS" clang lld
  stage_bin bin/clang /usr/local/bin/clang
  stage_bin bin/lld /usr/local/bin/lld
  ln -sf lld "$NATIVE/usr/local/bin/ld.lld"
  local res; res="$(ls -d lib/clang/*)"
  mkdir -p "$NATIVE/usr/local/lib/clang"; cp -a "$res" "$NATIVE/usr/local/lib/clang/"
}
recipe_smoke() {
  fixture /tmp/mpk-clang/hello.c <<'C'
#define N 6
int answer(void) { return N * 7; }
C
  smoke version "clang version" -- /usr/local/bin/clang --version
  SMOKE_TIMEOUT=180 smoke preprocess "6 * 7" -- /usr/local/bin/clang -E /tmp/mpk-clang/hello.c
  SMOKE_TIMEOUT=180 smoke compile-obj "" -- /usr/local/bin/clang -O2 -c /tmp/mpk-clang/hello.c -o /tmp/mpk-clang/hello.o
  smoke lld-version "LLD" -- /usr/local/bin/ld.lld --version
}
