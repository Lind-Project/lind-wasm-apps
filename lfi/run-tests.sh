#!/bin/bash
# run-tests.sh <app>...: run the apps' own run_tests.sh (the ones `make test` runs
# for the wasm build) against the LFI build, unmodified.
#   LFI_GRATES="/grates/strace-grate" lfi/run-tests.sh sed     # under a grate
# The scripts expect a lind-wasm tree: a root with `lindfs/` (here the rootfs)
# and a `lind_run` command (lfi/lind_run) on PATH.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/env.sh"
root=$BUILD/lindroot
mkdir -p "$root/build" "$root/bin" "$ROOTFS/tmp" "$ROOTFS/grates"
ln -sfn "$ROOTFS" "$root/lindfs"
[ -e "$ROOTFS/bin" ] || ln -s usr/local/bin "$ROOTFS/bin"
cp "$GRATES"/*-grate "$ROOTFS/grates/" 2>/dev/null
for g in "$GRATES"/rust/*-grate; do   # Rust grates: rs-<name>, and <name> unless a C grate has it
    cp "$g" "$ROOTFS/grates/rs-$(basename "$g")" 2>/dev/null
    cp -n "$g" "$ROOTFS/grates/" 2>/dev/null
done
printf '#!/bin/sh\necho "lind-boot is not part of the LFI build" >&2; exit 127\n' > "$root/build/lind-boot"; chmod +x "$root/build/lind-boot"
ln -sf "$HERE/lind_run" "$root/bin/lind_run"
mkdir -p "$root/scripts/bin"; ln -sf "$HERE/lind_run" "$root/scripts/bin/lind_run"
# some scripts run lind_run through sudo (lind-boot needs root); here it is not needed
printf '#!/bin/sh\nwhile [ "${1#-}" != "$1" ]; do shift; done\nexec "$@"\n' > "$root/bin/sudo"; chmod +x "$root/bin/sudo"
# the wasm pipeline stages each app under build/<app>/; the scripts check for it
mkdir -p "$APPS_ROOT/build"; for a in sed grep awk make coreutils diffutils; do ln -sfn "$ROOTFS" "$APPS_ROOT/build/$a"; done
export LIND_WASM_ROOT=$root PATH="$root/bin:$PATH"
rc=0
for app in "$@"; do
    echo "################ $app${LFI_GRATES:+  (under $LFI_GRATES)}"
    ( ulimit -u $(( $(ps -u "$(id -un)" -L --no-headers | wc -l) + 1500 ))
      cd "$APPS_ROOT/$app" && setsid /usr/bin/timeout -k 10 "${TMO:-900}" "./run_tests.sh" "$app" ) || rc=1
    pkill -x lfi-3i-run 2>/dev/null
done
exit $rc
