# ed25519 (orlp): library + its bundled test/benchmark program
KIND=library
recipe_build() {
  "$MPK_CC" $CFLAGS -o ed25519-test test.c src/*.c
  stage_bin ed25519-test /usr/local/bin/ed25519-test
}
recipe_smoke() {
  SMOKE_TIMEOUT=300 smoke test "valid signature" -- /usr/local/bin/ed25519-test
}
