# GNU grep 3.12
recipe_build() {
  autotools_touch
  mpk_configure --disable-nls --disable-perl-regexp
  make -j"$JOBS"
  stage_bin src/grep /usr/local/bin/grep
}
recipe_smoke() {
  printf 'hello world\nHello World\nno match\n' | fixture /tmp/mpk-grep/in.txt
  smoke version "GNU grep" -- /usr/local/bin/grep --version
  smoke match "hello world" -- /usr/local/bin/grep hello /tmp/mpk-grep/in.txt
  smoke ignore-case "Hello World" -- /usr/local/bin/grep -i HELLO /tmp/mpk-grep/in.txt
  smoke count "2" -- /usr/local/bin/grep -ci hello /tmp/mpk-grep/in.txt
  smoke regex "no match" -- /usr/local/bin/grep -E '^no +m' /tmp/mpk-grep/in.txt
  smoke no-match "" --exit 1 -- /usr/local/bin/grep zzz /tmp/mpk-grep/in.txt
}
