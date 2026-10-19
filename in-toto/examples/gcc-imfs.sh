#!/bin/bash
# gcc + IMFS grate + in-toto, all inside lind (no SGX).
#
# in-toto-cli runs as an ordinary cage under the IMFS grate. It forks and execs
# gcc, gcc writes the ELF into the in-memory filesystem, in-toto hashes it and
# signs the "build" link. A second in-toto step ("write-code") records hello.c,
# a layout ties the two together, and verify checks the chain. Then hello.c is
# tampered, the build is redone, and verify must fail.
#
# Needs, under $LIND_WASM_ROOT/lindfs:
#   /usr/local/bin/{gcc,cc1,as,ld}   gcc closure precompiled for this lind-boot
#   /usr/include, /usr/local/lib/gcc, /usr/lib/x86_64-linux-gnu, /lib64  (see gcc-preloads.txt)
#   /grates/imfs-grate.cwasm         Rust imfs-grate built on the same branch
#   /usr/local/bin/in-toto-cli.opt.cwasm
# Run as root (lind-boot chroots). Verified 2026-09-13 in container lind-coreutils-aug3.
set -u
ROOT="${LIND_WASM_ROOT:-/home/lind/lind-wasm}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
LB="timeout -s KILL 300 ./build/lind-boot"
CLI=/usr/local/bin/in-toto-cli.opt.cwasm
GRATE=/grates/imfs-grate.cwasm
GCC_CMD="/usr/local/bin/gcc -B/usr/local/bin/ -B/usr/lib/x86_64-linux-gnu/ -isystem /usr/include /hello.c -o /hello_it"
q() { grep -v "LIND DEBUG"; }  # lind-boot prints these on stderr; callers pipe 2>&1

cp "$HERE/hello.c" lindfs/hello.c
mkdir -p lindfs/keys lindfs/links lindfs/tmp
rm -f lindfs/links/*.link

echo "== keys"
$LB $CLI keygen /keys/owner.pk8 /keys/owner.pub.json 2>&1 | q
$LB $CLI keygen /keys/f.pk8 /keys/f.pub.json 2>&1 | q
FKEY=$(sed -n 's/.*"keyid": "\([0-9a-f]\{8\}\).*/\1/p' lindfs/keys/f.pub.json | head -1)

echo "== step write-code (records hello.c)"
$LB $CLI run --name write-code --key /keys/f.pk8 --out /links --products /hello.c --lstrip / 2>&1 | q

build() {
  # One grate launch: in-toto -> gcc -> cc1/as/ld, all on the in-memory FS.
  export PRELOADS="$(cat "$HERE/gcc-preloads.txt"):/keys/f.pk8"
  export DUMPS="/build.$FKEY.link=/links/build.$FKEY.link;/hello_it=/tmp/hello_it"
  $LB --env PRELOADS --env DUMPS $GRATE $CLI run --name build --key /keys/f.pk8 --out / \
    --materials /hello.c --products /hello_it --lstrip / -- $GCC_CMD 2>&1 | q | grep -v preloading
}
echo "== step build (gcc under the IMFS grate)"
build
sha256sum lindfs/tmp/hello_it

echo "== layout + verify (expect VERIFIED)"
$LB $CLI gen-layout --key /keys/owner.pk8 --step-key /keys/f.pub.json --out /root.layout \
  --src hello.c --pkg hello_it --step-pkg build -- $GCC_CMD 2>&1 | q
$LB $CLI verify --layout /root.layout --key /keys/owner.pub.json --links /links 2>&1 | q

echo "== tamper hello.c, rebuild, verify (expect FAILED)"
printf '\n/* tampered */\n' >> lindfs/hello.c
build
$LB $CLI verify --layout /root.layout --key /keys/owner.pub.json --links /links 2>&1 | q
