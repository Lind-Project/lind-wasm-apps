# GNU coreutils (all programs, installed into /bin like the wasm build)
recipe_build() {
  autotools_touch
  # This coreutils' gnulib predates glibc 2.28's libio cleanup; restore the
  # two macros its stdio internals (fseterr, freadahead, ...) key on.
  export CFLAGS="$CFLAGS -D_IO_ftrylockfile -D_IO_IN_BACKUP=0x100"
  FORCE_UNSAFE_CONFIGURE=1 mpk_configure --disable-nls --without-openssl --without-selinux \
    --without-libgmp --disable-acl --disable-xattr --enable-no-install-program=stdbuf
  make -j"$JOBS"
  local f
  for f in src/*; do
    [[ -f "$f" && -x "$f" && "$f" != *.* ]] || continue
    head -c4 "$f" | grep -q ELF || continue
    stage_bin "$f" "/bin/$(basename "$f")"
  done
  [[ -f "$NATIVE/bin/ginstall" ]] && mv "$NATIVE/bin/ginstall" "$NATIVE/bin/install"
}
recipe_smoke() {
  printf 'b\na\nc\n' | fixture /tmp/mpk-coreutils/in.txt
  smoke echo "hi there" -- /bin/echo hi there
  smoke cat "b" -- /bin/cat /tmp/mpk-coreutils/in.txt
  smoke sort "a" -- /bin/sort /tmp/mpk-coreutils/in.txt
  smoke wc "3" -- /bin/wc -l /tmp/mpk-coreutils/in.txt
  smoke ls "in.txt" -- /bin/ls -l /tmp/mpk-coreutils
  smoke mkdir "" -- /bin/mkdir -p /tmp/mpk-coreutils/d/e
  smoke cp "" -- /bin/cp /tmp/mpk-coreutils/in.txt /tmp/mpk-coreutils/d/e/copy.txt
  smoke stat-copy "regular file" -- /bin/stat /tmp/mpk-coreutils/d/e/copy.txt
  smoke rm "" -- /bin/rm -r /tmp/mpk-coreutils/d
  smoke sha256sum "in.txt" -- /bin/sha256sum /tmp/mpk-coreutils/in.txt
  smoke date "" -- /bin/date +%Y
  smoke head "c" -- /bin/head -n 3 /tmp/mpk-coreutils/in.txt
  smoke env "MPK=1" -- /bin/env MPK=1 /bin/env
  smoke false "" --exit 1 -- /bin/false
}
