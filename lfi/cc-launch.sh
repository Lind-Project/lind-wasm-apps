#!/bin/bash
# CC for a build whose programs are run by a host test harness: the LFI clang,
# and every linked executable becomes a launcher (launch.sh) next to the real
# binary (<name>.lfi).
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/env.sh"
args=("$@")
for a in "$@"; do [ "$a" = -shared ] && { args=(); for b in "$@"; do [ "$b" != -static-pie ] && args+=("$b"); done; }; done
"$CC" "${args[@]}" || exit $?
link=1; out=a.out; prev=
for a in "$@"; do
    case $a in -c|-E|-S|-M|-MM|-shared) link=0 ;; esac
    [ "$prev" = -o ] && out=$a
    prev=$a
done
if [ $link = 1 ] && [ -f "$out" ] && [ "$(head -c4 "$out")" = $'\x7fELF' ]; then
    mv "$out" "$out.lfi"
    printf '#!/bin/bash\nexec "%s/launch.sh" "$0.lfi" "$@"\n' "$HERE" > "$out"
    chmod +x "$out"
fi
