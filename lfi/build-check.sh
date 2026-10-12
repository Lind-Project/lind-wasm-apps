#!/bin/bash
# build-check.sh <app>: build <app> so that its own test suite can run on the host
# against the sandboxed programs (every program is a launcher; see launch.sh).
# Only coreutils so far.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/env.sh"
app=$1
src=$BUILD/src/$app; obj=$BUILD/check/$app
[ -d "$src" ] || "$HERE/build-app.sh" "$app" >/dev/null 2>&1 || true   # creates the prepared source copy
mkdir -p "$obj"; cd "$obj"
case $app in
  coreutils)
    if [ ! -f Makefile ]; then
        CC="$HERE/cc-launch.sh" CPPFLAGS="-D_GNU_SOURCE -DHAVE___FREADPTRINC=1" FORCE_UNSAFE_CONFIGURE=1 \
          "$src/configure" --build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --prefix=/usr/local \
          --disable-nls --disable-dependency-tracking --disable-libcap --disable-acl --disable-xattr \
          --without-gmp --enable-no-install-program=stdbuf > configure.log 2>&1
    fi
    make -j"$JOBS" CC="$HERE/cc-launch.sh" ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=: \
         MANS= dist_man1_MANS= > make.log 2>&1
    # the real binaries under their own names, for programs that run programs
    mkdir -p elfbin; for f in src/*.lfi; do ln -sf "$PWD/$f" "elfbin/$(basename "${f%.lfi}")"; done ;;
  *) echo "no check recipe for $app" >&2; exit 2 ;;
esac
echo "[$app] check build ready: $obj"
