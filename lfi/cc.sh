#!/bin/bash
# CC for the build proper: the LFI clang. A shared object (which nothing can
# load in LFI, but some packages build for LD_PRELOAD helpers) is linked
# without -static-pie, which cannot be combined with -shared.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
args=("$@")
for a in "$@"; do
    if [ "$a" = -shared ]; then
        args=(); for b in "$@"; do [ "$b" != -static-pie ] && args+=("$b"); done
        break
    fi
done
exec x86_64_lfi-linux-musl-clang "${args[@]}"
