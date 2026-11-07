# perl 5 with static extensions (no dynamic loading: lindfs has no rewritten XS .so files)
RUNTIME_DEPS=(bash coreutils)
recipe_build() {
  ./Configure -des -Dcc="$MPK_CC" -Dld="$MPK_CC" -Doptimize="$CFLAGS" \
    -Dprefix=/usr/local -Uusedl -Dlibswanted="m pthread dl c" -Dlibpth="/usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu" \
    -Uinstallusrbinperl -Dman1dir=none -Dman3dir=none
  make -j"$JOBS"
  make DESTDIR="$SRC/inst" install
  mkdir -p "$NATIVE/usr/local"
  cp -a "$SRC/inst/usr/local/." "$NATIVE/usr/local/"
  rm -f "$NATIVE/usr/local/bin/perl"; cp "$SRC/inst/usr/local/bin/perl" "$NATIVE/usr/local/bin/perl"
}
recipe_smoke() {
  printf 'b 2\na 1\nc 3\n' | fixture /tmp/mpk-perl/in.txt
  smoke version "This is perl 5" -- /usr/local/bin/perl -v
  smoke print "hello mpk" -- /usr/local/bin/perl -e 'print "hello mpk\n"'
  smoke regex "a=1;b=2;c=3" -- /usr/local/bin/perl -e 'open my $f, "<", "/tmp/mpk-perl/in.txt" or die; my %h = map { /(\w) (\d)/ } <$f>; print join(";", map {"$_=$h{$_}"} sort keys %h), "\n"'
  smoke modules "ok 3" -- /usr/local/bin/perl -MPOSIX -MList::Util=sum -MData::Dumper -e 'print "ok ", sum(1,2), "\n"'
  smoke digest "5d41402abc4b2a76" -- /usr/local/bin/perl -MDigest::MD5=md5_hex -e 'print md5_hex("hello"), "\n"'
  smoke fork-wait "child 7" -- /usr/local/bin/perl -e 'my $p = fork; if (!$p) { exit 7 } waitpid($p, 0); print "child ", $? >> 8, "\n"'
  smoke backticks "from-sh" -- /usr/local/bin/perl -e 'print `echo from-sh`'
}
