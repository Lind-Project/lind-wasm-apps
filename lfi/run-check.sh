#!/bin/bash
# run-check.sh <app> [TESTS...]: run <app>'s own test suite against the sandboxed
# programs (build-check.sh first). Safe to run: the whole run is one session
# that is killed at the end (tests start background programs and expect to kill
# them by pid, which a sandboxed `kill` cannot do), with a cap on processes.
#   LFI_GRATES="/path/strace-grate" run-check.sh coreutils misc/basename   (grates in front)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/env.sh"
app=$1; shift
chk=$BUILD/check/$app
case $app in
  coreutils) dir=$chk/tests; target=check
             tests=(); [ $# -gt 0 ] && tests=(TESTS="$*") ;;
  *) echo "no check recipe for $app" >&2; exit 2 ;;
esac
log=${LOG:-$chk/check.log}
sidf=$(mktemp)
(
  ulimit -u $(( $(ps -u "$(id -un)" -L --no-headers | wc -l) + ${NPROC:-1500} ))
  export LFI_ELFBIN=$chk/elfbin
  cd "$dir" && setsid bash -c 'echo $$ > "$0"; exec "${@:1}"' "$sidf" \
     /usr/bin/timeout -k 10 "${TMO:-3000}" make -k "$target" "${tests[@]}" \
     ACLOCAL=: AUTOCONF=: AUTOMAKE=: AUTOHEADER=: MAKEINFO=: > "$log" 2>&1
)
sid=$(cat "$sidf"); rm -f "$sidf"
[ -n "$sid" ] && pkill -KILL -s "$sid" 2>/dev/null
grep -E "^(PASS|FAIL|SKIP|XFAIL|XPASS|ERROR):" "$log" | sort | uniq -c | awk '{print $2}' | sort | uniq -c
grep -E "^# (TOTAL|PASS|FAIL|SKIP)" "$log"
