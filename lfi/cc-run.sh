#!/bin/bash
# CC for ./configure: the LFI clang, except that a linked executable is turned
# into a launcher that runs the real binary in the sandbox. configure's
# "can I run a test program?" then works, and its runtime checks measure the
# real (musl) behaviour instead of falling back to cross-compilation guesses.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
"$CC" "$@" || exit $?
link=1; out=a.out; prev=
for a in "$@"; do
    case $a in -c|-E|-S|-M|-MM) link=0 ;; esac
    [ "$prev" = -o ] && out=$a
    prev=$a
done
if [ $link = 1 ] && [ -f "$out" ] && [ "$(head -c4 "$out")" = $'\x7fELF' ]; then
    mv "$out" "$out.lfi"
    printf '#!/bin/sh\nexec "%s" "$0.lfi" "$@"\n' "$RUN" > "$out"
    chmod +x "$out"
fi
