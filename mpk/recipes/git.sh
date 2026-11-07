# git (Makefile build) with static zlib; no curl/perl/python/gettext
DEPS=(zlib)
RUNTIME_DEPS=(bash coreutils)
recipe_build() {
  local opts=(CC="$MPK_CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" ZLIB_PATH="$PREFIX"
    prefix=/usr/local NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_EXPAT=1
    NO_CURL=1 NO_OPENSSL=1 NO_ICONV=1 NO_INSTALL_HARDLINKS=1 INSTALL_SYMLINKS=1)
  make -j"$JOBS" "${opts[@]}" all
  make "${opts[@]}" DESTDIR="$SRC/inst" install
  mkdir -p "$NATIVE/usr/local"
  cp -a "$SRC/inst/usr/local/." "$NATIVE/usr/local/"
  rm -rf "$NATIVE/usr/local/share/man" "$NATIVE/usr/local/share/gitweb" "$NATIVE/usr/local/share/perl5"
}
recipe_smoke() {
  local g=(/usr/local/bin/git -c user.name=mpk -c user.email=mpk@lind -c init.defaultBranch=main)
  fresh_dir /tmp/mpk-git
  smoke version "git version" -- /usr/local/bin/git --version
  smoke init "Initialized" -- "${g[@]}" init /tmp/mpk-git/repo
  printf 'hello\n' > "$LINDFS/tmp/mpk-git/repo/a.txt" 2>/dev/null || true
  smoke add "" -- "${g[@]}" -C /tmp/mpk-git/repo add a.txt
  smoke commit "" -- "${g[@]}" -C /tmp/mpk-git/repo commit -q -m first
  smoke log "first" -- "${g[@]}" -C /tmp/mpk-git/repo log --oneline
  smoke status "nothing to commit" -- "${g[@]}" -C /tmp/mpk-git/repo status
  smoke clone "" -- "${g[@]}" clone -q /tmp/mpk-git/repo /tmp/mpk-git/clone
  smoke cat-file "hello" -- "${g[@]}" -C /tmp/mpk-git/clone cat-file -p HEAD:a.txt
}
