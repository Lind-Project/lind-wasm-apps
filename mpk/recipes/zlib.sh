# zlib: static library for curl/git/cpython plus its own example/minigzip programs
KIND=library
recipe_build() {
  ./configure --static --prefix="$PREFIX"
  make -j"$JOBS" libz.a example minigzip
  make install
  stage_bin example /usr/local/bin/zlib-example
  stage_bin minigzip /usr/local/bin/minigzip
}
recipe_smoke() {
  seq 1 2000 2>/dev/null | fixture /tmp/mpk-zlib/data.txt
  smoke example "zlib version" -- /usr/local/bin/zlib-example /tmp/mpk-zlib/foo.gz
  smoke compress "" -- /usr/local/bin/minigzip /tmp/mpk-zlib/data.txt
  smoke decompress "" -- /usr/local/bin/minigzip -d /tmp/mpk-zlib/data.txt.gz
  if cmp -s <(seq 1 2000) "$LINDFS/tmp/mpk-zlib/data.txt"; then echo "SMOKE PASS: roundtrip-content"
  else echo "SMOKE FAIL: roundtrip-content — decompressed data differs"; fi
}
