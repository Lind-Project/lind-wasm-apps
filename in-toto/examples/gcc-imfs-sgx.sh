#!/bin/bash
# gcc + IMFS grate + in-toto inside an SGX enclave, through TriSeal's enarx.
#
# Same flow as gcc-imfs.sh, but every step is an `enarx run`. The build step
# runs the IMFS grate as the enarx workload; in-toto-cli is the grate's child,
# forks gcc, and signs the ELF that gcc wrote into the in-memory filesystem.
#
# Differences from the container version, all forced by enarx:
#   - No chroot. Every path is host-absolute, including the paths inside the
#     Enarx.toml args and the PRELOADS/DUMPS lists.
#   - enarx takes one positional wasm path. The child program and its args go
#     in the Enarx.toml `args` list; PRELOADS/DUMPS go in its `[env]` table.
#   - The exec target is loaded through the grate, so in-toto-cli.cwasm itself
#     must be in PRELOADS.
#   - ld's libc.so linker script names /lib/x86_64-linux-gnu/libc.so.6 and two
#     more absolute paths. IMFS cannot rename a preload, so the host's own
#     copies of those three files are preloaded as well.
#   - in-toto-cli's --out directory must exist in IMFS, so it points at the
#     directory a preloaded file already created.
#
# Needs, under $LINDFS (host-absolute lindfs root):
#   usr/local/bin/{gcc,cc1,as,ld}       gcc closure precompiled for enarx's lind-boot
#   usr/include, usr/local/lib/gcc, usr/lib/x86_64-linux-gnu, lib64  (gcc-preloads.txt)
#   grates/imfs-grate.cwasm             built on the same branch as enarx's lind-boot
#   usr/local/bin/in-toto-cli.cwasm     built against the SAME sysroot enarx's
#                                       lind-boot was built from (a container
#                                       build can carry a debug:: import enarx
#                                       cannot satisfy)
# Verified 2026-09-16 on lind-server-3, ENARX_BACKEND=sgx: VERIFIED, then
# FAILED after tampering. build step 41 s.
set -u
LINDFS="${LINDFS:-$HOME/lind-wasm/lindfs}"
ENARX="${ENARX:-$HOME/.cargo/bin/enarx}"
BACKEND="${ENARX_BACKEND:-sgx}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
W="$LINDFS/in-toto-sgx"           # work dir, host-absolute, doubles as the IMFS path
CLI="$LINDFS/usr/local/bin/in-toto-cli.cwasm"
GRATE="$LINDFS/grates/imfs-grate.cwasm"
GCC15="$LINDFS/usr/local/lib/gcc/x86_64-linux-gnu/15.2.0"
GCC_CMD="$LINDFS/usr/local/bin/gcc -B$LINDFS/usr/local/bin/ -B$LINDFS/usr/lib/x86_64-linux-gnu/ -B$GCC15/ -isystem $GCC15/include -isystem $LINDFS/usr/include $W/hello.c -o $W/hello_it"
GCC_PRE="$(tr ':' '\n' < "$HERE/gcc-preloads.txt" | grep -v '^/hello.c$' | sed "s#^#$LINDFS#" | paste -sd:)"
HOST_LIBC="/lib/x86_64-linux-gnu/libc.so.6:/usr/lib/x86_64-linux-gnu/libc_nonshared.a:/lib64/ld-linux-x86-64.so.2"
NOISE='^\[deser\]|^\[instrument\]|^\[mmap_inner\]|^\[debug\]|^\[stack-arena\]|^\[fork-shared-error\]|^\[fork_vmmap|^\[mmap-syscall|^\[vmmap-add|^execve called|failed to enable wasm cache|preloading|munmap failed: 95|^$'

rm -rf "$W"; mkdir -p "$W/links" "$W/toml"
cp "$HERE/hello.c" "$W/hello.c"

# Write an Enarx.toml: args list, then optional PRELOADS/DUMPS env.
toml() { local f=$1 pre=$2 dump=$3; shift 3
  { printf 'args = ['; local sep=""; for a in "$@"; do printf '%s"%s"' "$sep" "$a"; sep=", "; done; printf ']\n'
    [ -n "$pre$dump" ] && printf '[env]\nPRELOADS = "%s"\nDUMPS = "%s"\n' "$pre" "$dump"; } > "$f"; }
# Run in-toto-cli directly as the enarx workload.
direct() { local name=$1; shift; toml "$W/toml/$name.toml" "" "" "$@"
  timeout -s KILL 300 env LIND_GRATE_WORKERS=1 ENARX_BACKEND=$BACKEND ENARX_WASMCFGFILE="$W/toml/$name.toml" "$ENARX" run "$CLI" 2>&1 | grep -Ev "$NOISE"; }
# Run the IMFS grate as the workload with in-toto-cli as its child, which forks gcc.
build() { local name=$1
  toml "$W/toml/$name.toml" "$CLI:$GCC_PRE:$HOST_LIBC:$W/func.pk8:$W/hello.c" \
       "$W/build.$FKEY.link=$W/links/build.$FKEY.link;$W/hello_it=$W/hello_it" \
       "$CLI" run --name build --key "$W/func.pk8" --out "$W" --materials "$W/hello.c" --products "$W/hello_it" --lstrip "$W/" -- $GCC_CMD
  rm -f "$W/hello_it"
  timeout -s KILL 3600 env LIND_GRATE_WORKERS=1 ENARX_BACKEND=$BACKEND ENARX_WASMCFGFILE="$W/toml/$name.toml" "$ENARX" run "$GRATE" 2>&1 | grep -Ev "$NOISE"
  sha256sum "$W/hello_it"; grep -o '"sha256": "[0-9a-f]*"' "$W/links/build.$FKEY.link" | tail -1; }

echo "== keys (generated inside the enclave)"
direct keygen-owner keygen "$W/owner.pk8" "$W/owner.pub.json"
direct keygen-func  keygen "$W/func.pk8"  "$W/func.pub.json"
FKEY=$(sed -n 's/.*"keyid": "\([0-9a-f]\{8\}\).*/\1/p' "$W/func.pub.json" | head -1)

echo "== step write-code (records hello.c)"
direct write-code run --name write-code --key "$W/func.pk8" --out "$W/links" --products "$W/hello.c" --lstrip "$W/"

echo "== step build (in-toto forks gcc under the IMFS grate, in the enclave)"
build build1

echo "== layout + verify (expect VERIFIED)"
direct gen-layout gen-layout --key "$W/owner.pk8" --step-key "$W/func.pub.json" --out "$W/root.layout" \
  --expires 2030-01-01T00:00:00Z --src hello.c --pkg hello_it --step-pkg build -- $GCC_CMD
direct verify verify --layout "$W/root.layout" --key "$W/owner.pub.json" --links "$W/links"

echo "== tamper hello.c, rebuild, verify (expect FAILED)"
printf '\n/* tampered */\n' >> "$W/hello.c"
build build2
direct verify2 verify --layout "$W/root.layout" --key "$W/owner.pub.json" --links "$W/links"
