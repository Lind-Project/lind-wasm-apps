# GNU awk (gawk)
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls --disable-extensions --without-readline --without-mpfr
  make -j"$JOBS"
  stage_bin gawk /usr/local/bin/gawk
}
recipe_smoke() {
  printf 'alice 3\nbob 5\ncarol 7\n' | fixture /tmp/mpk-awk/in.txt
  smoke version "GNU Awk" -- /usr/local/bin/gawk --version
  smoke begin "42" -- /usr/local/bin/gawk 'BEGIN { print 6*7 }'
  smoke sum-fields "15" -- /usr/local/bin/gawk '{ s += $2 } END { print s }' /tmp/mpk-awk/in.txt
  smoke regex-printf "bob=5" -- /usr/local/bin/gawk '/^b/ { printf "%s=%d\n", $1, $2 }' /tmp/mpk-awk/in.txt
  smoke assoc-array "3" -- /usr/local/bin/gawk '{ a[$1] = $2 } END { print length(a) }' /tmp/mpk-awk/in.txt
}
