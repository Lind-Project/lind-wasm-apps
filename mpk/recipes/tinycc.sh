# Tiny C Compiler targeting x86-64, using lind's glibc in lindfs as its runtime
UPSTREAM_TESTS=0
NOTE="Upstream run_tests.sh targets i386 (wasm build) and needs sudo + an i686 cross toolchain; replaced by smoke tests."
recipe_build() {
  ./configure --cc="$MPK_CC" --prefix=/usr/local --tccdir=/usr/local/lib/tcc \
    --crtprefix=/usr/local/lib/tcc/crt --libpaths=/lib/elf:/usr/local/lib/tcc \
    --sysincludepaths='{B}/include':/usr/local/include:/usr/include/x86_64-linux-gnu:/usr/include \
    --elfinterp=/lib/elf/ld.so --extra-cflags="$CFLAGS"
  make -j"$JOBS" tcc libtcc1.a
  stage_bin tcc /bin/tcc
  install -D -m 644 libtcc1.a "$NATIVE/usr/local/lib/tcc/libtcc1.a"
  mkdir -p "$NATIVE/usr/local/lib/tcc/include"; cp include/*.h "$NATIVE/usr/local/lib/tcc/include/"
}
recipe_smoke() {
  fixture /tmp/mpk-tcc/hello.c <<'C'
int printf(const char *, ...);
int main(void) { printf("tcc says %d\n", 6 * 7); return 0; }
C
  smoke version "tcc version" -- /bin/tcc -v
  smoke preprocess "6 * 7" -- /bin/tcc -E /tmp/mpk-tcc/hello.c
  smoke compile "" -- /bin/tcc -c /tmp/mpk-tcc/hello.c -o /tmp/mpk-tcc/hello.o
  smoke run "tcc says 42" -- /bin/tcc -nostdlib -run /tmp/mpk-tcc/hello.c
}
