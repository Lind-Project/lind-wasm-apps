#!/bin/bash
# launch.sh <lfi-binary> args...: run an LFI program in the sandbox for a test
# harness that runs on the host (the harness's PATH finds launchers; this runs
# the real binary). The host environment is passed through (lfi-3i-run does not
# inherit it); LFI_GRATES (host paths, space separated) is a grate chain to put
# in front of the program, e.g. LFI_GRATES="$GRATES/strace-grate".
# Programs that start other programs find the real binaries first on PATH
# (launchers are scripts the sandbox cannot exec): LFI_ELFBIN.
#
# This runs on the host with the harness's PATH, which starts with the build
# directory full of launchers: every tool used here must be found on a fixed
# host PATH, or a launcher would launch itself forever. A depth guard backs that up.
HOSTPATH=$PATH
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LFI_LAUNCH_DEPTH=$(( ${LFI_LAUNCH_DEPTH:-0} + 1 ))
if [ "$LFI_LAUNCH_DEPTH" -gt 4 ]; then
    echo "launch.sh: runaway recursion, refusing to start $1" >&2
    exit 125
fi
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
prog=$1; shift
args=()
while IFS= read -r -d '' kv; do
    case $kv in LFI_*|PATH=*) continue ;; esac
    args+=(--env "$kv")
done < <(/usr/bin/env -0)
args+=(--env "PATH=${LFI_ELFBIN:+$LFI_ELFBIN:}$HOSTPATH")
read -ra chain <<< "${LFI_GRATES:-}"
# (with no grate the program's argv[0] is its invoked name, as under exec -a;
# a grate execs its child with the path it was given)
name=$(basename "${prog%.lfi}")
if [ ${#chain[@]} -eq 0 ]; then
    exec "$RUN" "${args[@]}" --argv0="$name" "$prog" "$@"
fi
exec "$RUN" "${args[@]}" "${chain[@]}" "$prog" "$@"
