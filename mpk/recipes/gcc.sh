# GCC C compiler driver + cc1 (make all-gcc), GMP/MPFR/MPC built in-tree.
# Assembling/linking needs binutils inside lindfs.
RUNTIME_DEPS=(binutils)
UPSTREAM_TESTS=0
NOTE="Needs network access once: contrib/download_prerequisites fetches GMP/MPFR/MPC."
recipe_build() {
  [[ -d gmp && -d mpfr && -d mpc ]] || ./contrib/download_prerequisites --no-isl --no-verify
  mkdir -p obj && cd obj
  ../configure CC="$MPK_CC" CXX="$MPK_CXX" CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ \
    --prefix=/usr/local --enable-languages=c --disable-bootstrap --disable-multilib \
    --disable-nls --disable-shared --disable-plugin --disable-lto --without-isl \
    --without-zstd --disable-libsanitizer MAKEINFO=true
  make -j"$JOBS" MAKEINFO=true all-gcc
  stage_bin gcc/xgcc /usr/local/bin/gcc
  local libexec=/usr/local/libexec/gcc/x86_64-pc-linux-gnu/$(cat ../gcc/BASE-VER)
  stage_bin gcc/cc1 "$libexec/cc1"
}
recipe_smoke() {
  fixture /tmp/mpk-gcc/hello.c <<'C'
#define N 6
int answer(void) { return N * 7; }
C
  smoke version "gcc version" -- /usr/local/bin/gcc -v
  SMOKE_TIMEOUT=180 smoke preprocess "6 * 7" -- /usr/local/bin/gcc -E /tmp/mpk-gcc/hello.c
  SMOKE_TIMEOUT=180 smoke compile-asm "" -- /usr/local/bin/gcc -O2 -S /tmp/mpk-gcc/hello.c -o /tmp/mpk-gcc/hello.s
  SMOKE_TIMEOUT=180 smoke compile-obj "" -- /usr/local/bin/gcc -O2 -c /tmp/mpk-gcc/hello.c -o /tmp/mpk-gcc/hello.o
}
