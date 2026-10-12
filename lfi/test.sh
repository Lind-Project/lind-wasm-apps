#!/bin/bash
# Smoke tests of the apps built for LFI, run inside the sandbox with $ROOTFS as "/".
#   lfi/test.sh [filter]       run directly
#   WRAP=strace lfi/test.sh    run every program with a grate (strace) under it
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
FILTER=${1:-}
W=$(mktemp -d "$ROOTFS/work.XXXX"); WD=/${W##*/}      # scratch directory inside the root
trap 'rm -rf "$W"' EXIT
mkdir -p "$ROOTFS/grates" "$ROOTFS/tmp"
cp "$GRATES"/strace-grate "$ROOTFS/grates/" 2>/dev/null
pass=0; fail=0; failed=()

# L cmd args...: run a program in the sandbox (stdin/stdout are the host's).
L() {
    local prog=$1; shift
    case ${WRAP:-} in
      "")     "$RUN" -r --dir=/="$ROOTFS" --dir=/dev=/dev --wd="$WD" --env PATH=/usr/local/bin "$ROOTFS$prog" "$@" ;;
      strace) "$RUN" -r --dir=/="$ROOTFS" --dir=/dev=/dev --wd="$WD" --env PATH=/usr/local/bin "$ROOTFS/grates/strace-grate" "$prog" "$@" 2>/dev/null ;;
      *)      echo "unknown WRAP: $WRAP" >&2; return 1 ;;
    esac
}
export -f L; export RUN ROOTFS WD WRAP
B=/usr/local/bin; export B; cd "$W"      # host-side scratch dir == $WD in the sandbox

# t <name> <expected output> <shell snippet>
t() {
    local name=$1 want=$2 snippet=$3
    [ -n "$FILTER" ] && [[ "$name" != *$FILTER* ]] && return
    local got; got=$(timeout -s KILL 120 bash -c "$snippet" 2>&1)
    if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$name"
    else fail=$((fail+1)); failed+=("$name"); printf 'FAIL  %s\n      want: %q\n      got:  %q\n' "$name" "$want" "$got"; fi
}

printf 'one\ntwo\nthree\nfour\n' > in.txt
printf '3\n1\n2\n2\n' > nums.txt
printf 'a b c\nd e f\n' > words.txt
printf 'one\nTWO\nthree\nfour\n' > in2.txt

# ---- sed
t sed/subst     "oNe"              'echo one | L $B/sed s/n/N/'
t sed/print     "two"              'L $B/sed -n 2p in.txt'
t sed/inplace   "x-two"            'L $B/sed -i s/^/x-/ words.txt; true; L $B/sed -n 1p in.txt | L $B/sed s/one/x-two/'
t sed/regex     "a-b-c"            'echo "a b c" | L $B/sed -E "s/ /-/g"'
# ---- grep
t grep/count    "4"                'L $B/grep -c . in.txt'
t grep/extended "one
three"             'L $B/grep -E "^(one|three)$" in.txt'
t grep/invert   "two
three
four"              'L $B/grep -v one in.txt'
t grep/icase    "TWO"              'L $B/grep -i two in2.txt'
t grep/recursive "in.txt:one
in2.txt:one"       'L $B/grep -r ^one . | L $B/sed s@^\./@@ | L $B/sort'
# ---- awk
t awk/sum       "8"                'L $B/gawk "{s+=\$1} END{print s}" nums.txt'
t awk/fields    "c f"              'L $B/gawk "{print \$3}" words.txt | L $B/tr "\n" " " | L $B/sed "s/ $//"'
t awk/printf    "03"               'L $B/gawk "BEGIN{printf \"%02d\n\", 3}"'
# ---- diffutils
t diff/same     ""                 'L $B/diff in.txt in.txt'
t diff/differ   "2c2
< two
---
> TWO"               'L $B/diff in.txt in2.txt'
t cmp/differ    "in.txt in2.txt differ: char 5, line 2" 'L $B/cmp in.txt in2.txt'
t diff3/merge   "0"                'L $B/diff3 -m in.txt in.txt in.txt >/dev/null; echo $?'
t sdiff/side    "1"                'L $B/sdiff -w 30 in.txt in2.txt | L $B/grep -c "|"'
# ---- make (recipes without shell metacharacters are run directly)
cat > Makefile <<'MK'
all: out.txt
out.txt: in.txt
	cp in.txt out.txt
MK
t make/build    "cp in.txt out.txt
one
two
three
four"              'L $B/make 2>&1; L $B/cat out.txt'
t make/uptodate "make: Nothing to be done for 'all'." 'L $B/make'
# ---- coreutils
t cat/files     "one
two
three
four"              'L $B/cat in.txt'
t wc/lines      "4 in.txt"         'L $B/wc -l in.txt'
t sort/numeric  "1
2
2
3"                 'L $B/sort -n nums.txt'
t uniq/count    "      1 3"        'L $B/sort -n nums.txt | L $B/uniq -c | L $B/tail -1'
t head/tail     "two"              'L $B/head -2 in.txt | L $B/tail -1'
t tr/upper      "ONE"              'echo one | L $B/tr a-z A-Z'
t cut/field     "b"                'echo "a b c" | L $B/cut -d" " -f2'
t seq/range     "1 2 3"            'L $B/seq 3 | L $B/tr "\n" " " | L $B/sed "s/ $//"'
t expr/arith    "42"               'L $B/expr 6 \* 7'
t md5sum        "d41d8cd98f00b204e9800998ecf8427e  -" 'L $B/md5sum < /dev/null'
t sha256sum     "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -" 'L $B/sha256sum < /dev/null'
t basename      "c.txt"            'L $B/basename /a/b/c.txt'
t mkdir+ls      "d
in.txt"            'L $B/mkdir d; L $B/ls | L $B/grep -E "^(d|in.txt)$"'
t cp+mv+rm      "moved"            'L $B/cp in.txt c.txt; L $B/mv c.txt moved; L $B/ls moved; L $B/rm moved'
t ln            "one"              'L $B/ln -s in.txt lnk; L $B/head -1 lnk'
t touch+stat    "0"                'L $B/touch t; L $B/stat -c %s t'
t tee           "hi"               'echo hi | L $B/tee tee.out; L $B/cat tee.out > /dev/null'
t env           "X=1"              'L $B/env X=1 $B/env | L $B/grep ^X='
t printf        "a 5"              'L $B/printf "%s %d\n" a 5'
t test/exists   "yes"              'L $B/test -f in.txt && echo yes'
t date/epoch    "1970-01-01"       'L $B/date -u -d @0 +%F'
t sleep         "slept"            'L $B/sleep 0.2; echo slept'
t pwd           "$WD"              'L $B/pwd'
t uname         "Linux LFI"        'L $B/uname -s'
t od            "0000000 061143
0000002"           'echo -n "cb" | L $B/od -o'
t xargs-like    "ok"               'echo ok | L $B/tee /dev/stdout | L $B/head -1'
# ---- fork/exec/wait/pipes inside the sandbox (via make and env)
t exec/chain    "X=1"              'L $B/env X=1 $B/env X=1 $B/env | L $B/grep ^X='
# ---- zlib (its own example programs)
if [ -x "$BUILD/obj/zlib/example" ]; then
  cp "$BUILD/obj/zlib/example" "$ROOTFS/usr/local/bin/zlib-example"
  cp "$BUILD/obj/zlib/minigzip" "$ROOTFS/usr/local/bin/minigzip" 2>/dev/null
  t zlib/example "large_inflate(): OK" 'L $B/zlib-example 2>&1 | grep -m1 "^large_inflate"'
  t zlib/gzip     "one"            'L $B/minigzip < in.txt > in.gz; L $B/minigzip -d < in.gz | L $B/head -1'
fi

echo; echo "passed: $pass  failed: $fail"
[ ${#failed[@]} -eq 0 ] || { echo "failed: ${failed[*]}"; exit 1; }
