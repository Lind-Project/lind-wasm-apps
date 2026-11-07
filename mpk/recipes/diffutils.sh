# GNU diffutils
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls
  make -j"$JOBS"
  local b; for b in diff cmp diff3 sdiff; do stage_bin "src/$b" "/usr/local/bin/$b"; done
}
recipe_smoke() {
  printf 'one\ntwo\nthree\n' | fixture /tmp/mpk-diff/a.txt
  printf 'one\nTWO\nthree\n' | fixture /tmp/mpk-diff/b.txt
  smoke version "GNU diffutils" -- /usr/local/bin/diff --version
  smoke diff-unified "+TWO" --exit 1 -- /usr/local/bin/diff -u /tmp/mpk-diff/a.txt /tmp/mpk-diff/b.txt
  smoke diff-same "" -- /usr/local/bin/diff /tmp/mpk-diff/a.txt /tmp/mpk-diff/a.txt
  smoke cmp "differ" --exit 1 -- /usr/local/bin/cmp /tmp/mpk-diff/a.txt /tmp/mpk-diff/b.txt
  smoke diff3 "" --exit 1 -- /usr/local/bin/diff3 /tmp/mpk-diff/a.txt /tmp/mpk-diff/b.txt /tmp/mpk-diff/a.txt
}
