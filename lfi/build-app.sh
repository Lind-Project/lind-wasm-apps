#!/bin/bash
# build-app.sh <app>: build one app for LFI out of tree and install into $ROOTFS.
#  - sources come from `git archive HEAD <app>` (pristine: no in-tree state)
#  - ./configure runs in cross mode (the binaries cannot run on the host)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/env.sh"
app=$1
src=$BUILD/src/$app; obj=$BUILD/obj/$app
mkdir -p "$BUILD/src" "$obj" "$ROOTFS"
if [ ! -d "$src" ]; then
    # The working tree has the generated files (configure) that git does not
    # track; tracked files that were modified for the wasm build are put back
    # to their committed state (git show: no checkout).
    cp -a "$APPS_ROOT/$app" "$BUILD/src/$app"
    git -C "$APPS_ROOT" diff --name-only -- "$app" | while read -r f; do
        git -C "$APPS_ROOT" show "HEAD:$f" > "$BUILD/src/$f" 2>/dev/null || true
    done
    git -C "$APPS_ROOT" ls-files --deleted -- "$app" | while read -r f; do
        mkdir -p "$(dirname "$BUILD/src/$f")"; git -C "$APPS_ROOT" show "HEAD:$f" > "$BUILD/src/$f"
    done
    case $app in
      # coreutils bundles a gnulib too old to know musl's stdio internals; the
      # gnulib in this repo is newer.
      coreutils) cp "$HERE"/overlay/coreutils/lib/*.c "$BUILD/src/coreutils/lib/"
                 # (newer freadseek.c, with the musl primitive it uses declared)
                 sed 's|^#include "freadseek.h"|#include "freadseek.h"\nextern void __freadptrinc (FILE *, size_t); /* musl */|' \
                     "$APPS_ROOT/gnulib/lib/freadseek.c" > "$BUILD/src/coreutils/lib/freadseek.c" ;;
      # gawk's minrx.c counts trailing zeros with __builtin_ctzl, which the LFI
      # compiler turns into `rep bsf` on a %gs memory operand -- an encoding the
      # verifier's decoder does not know. It has a portable table-driven
      # fallback for compilers without the builtin; use that.
      awk) sed -i 's|^#ifdef __GNUC__$|#if 0 /* LFI: use the table-driven ctz below */|' "$BUILD/src/awk/support/minrx.c" ;;
    esac
fi
cd "$obj"
# configure runs its test programs through the sandbox (cc-run.sh) and is told it
# is not cross compiling; make then uses the plain compiler.
TRIPLE=x86_64-linux-musl   # (apps with an old config.sub use x86_64-pc-linux-gnu)
common=(--build=$TRIPLE --host=$TRIPLE --prefix=/usr/local --disable-nls --disable-dependency-tracking)
NOREGEN=(ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: HELP2MAN="$HERE/fake-help2man.sh" run_help2man="$HERE/fake-help2man.sh" MAKEINFO=:)   # generated files and docs: not rebuilt
INSTALLARGS=()   # extra arguments for make install
SUBDIRS=()   # per app: extra make arguments (build only some directories, skip man pages)
autotools() { CC="$HERE/cc-run.sh" "$src/configure" "${common[@]}" "$@" > configure.log 2>&1 && make -j"$JOBS" CC="$HERE/cc.sh" "${NOREGEN[@]}" "${SUBDIRS[@]}" > make.log 2>&1 \
              && make install DESTDIR="$ROOTFS" "${NOREGEN[@]}" "${SUBDIRS[@]}" "${INSTALLARGS[@]}" > install.log 2>&1; }
case $app in
  sed)       autotools --without-selinux ;;
  grep)      autotools --disable-perl-regexp ;;
  awk)       SUBDIRS=(SUBDIRS="support .")   # (awklib/doc/test run the built gawk on the host)
             autotools --without-readline --without-mpfr --disable-extensions --disable-pma ;;
  diffutils) SUBDIRS=(SUBDIRS="lib src"); autotools ;;
  make)      CFLAGS="$CFLAGS -Wno-incompatible-pointer-types" autotools --without-guile --disable-load ;;
  coreutils) INSTALLARGS=(INSTALL=/usr/bin/install "INSTALL_PROGRAM=/usr/bin/install -c")   # (ginstall is an LFI program)
             SUBDIRS=(MANS= dist_man1_MANS=)   # (man pages are made by running the built tools)
             TRIPLE=x86_64-pc-linux-gnu; common[0]=--build=$TRIPLE; common[1]=--host=$TRIPLE
             CPPFLAGS="-D_GNU_SOURCE -DHAVE___FREADPTRINC=1" FORCE_UNSAFE_CONFIGURE=1 autotools --without-selinux --disable-libcap --disable-acl \
                 --disable-xattr --without-gmp --enable-no-install-program=stdbuf ;;
  zlib)      # zlib's configure is not autoconf: build in a copy
             rm -rf "$obj"; cp -r "$src" "$obj"; cd "$obj"
             CHOST=x86_64-linux-musl ./configure --static --prefix=/usr/local > configure.log 2>&1 \
               && make -j"$JOBS" > make.log 2>&1 && make install DESTDIR="$ROOTFS" > install.log 2>&1 ;;
  *) echo "no recipe for $app" >&2; exit 2 ;;
esac
echo "[$app] built"
