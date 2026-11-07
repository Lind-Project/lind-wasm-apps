# GNU sed 4.9
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls
  make -j"$JOBS"
  stage_bin sed/sed /usr/local/bin/sed
}
recipe_smoke() {
  printf 'hello world\nfoo bar\n' | fixture /tmp/mpk-sed/in.txt
  smoke version "GNU sed" -- /usr/local/bin/sed --version
  smoke substitute "hello mpk" -- /usr/local/bin/sed s/world/mpk/ /tmp/mpk-sed/in.txt
  smoke delete-line "foo bar" -- /usr/local/bin/sed 1d /tmp/mpk-sed/in.txt
  smoke in-place "" -- /usr/local/bin/sed -i s/foo/baz/ /tmp/mpk-sed/in.txt
  smoke in-place-result "baz bar" -- /usr/local/bin/sed -n 2p /tmp/mpk-sed/in.txt
}
