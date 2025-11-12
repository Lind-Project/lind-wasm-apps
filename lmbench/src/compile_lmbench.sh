#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
: "${LIND_WASM_ROOT:=${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)/lind-wasm}}"

BASE_SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
LLVM_BIN="${LLVM_BIN:-$(ls -d "$LIND_WASM_ROOT"/clang+llvm-*/bin 2>/dev/null | head -n1)}"
APPS_MERGED="$REPO_ROOT/build/sysroot_merged"
LIBDIR="$APPS_MERGED/lib/wasm32-wasi"

[[ -x "$LLVM_BIN/clang" ]] || { echo "ERROR: clang not found"; exit 1; }
[[ -r "$BASE_SYSROOT/include/wasm32-wasi/stdio.h" ]] || { echo "ERROR: sysroot missing"; exit 1; }
[[ -r "$LIBDIR/libc.a" ]] || { echo "ERROR: merged sysroot missing; run: make merge-sysroot"; exit 1; }

REAL_CC="$LLVM_BIN/clang --target=wasm32-unknown-wasi --sysroot=$APPS_MERGED"
CFLAGS=" -O2 -g -I$APPS_MERGED/include -I$APPS_MERGED/include/wasm32-wasi -I$APPS_MERGED/include/tirpc "
LDFLAGS=" -L$LIBDIR -Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low "
LIBS=" -lc -lm -lpthread -ltirpc "

# wrapper for makefile calls
mkdir -p "$REPO_ROOT/lmbench/scripts"
cat > "$REPO_ROOT/lmbench/scripts/compiler" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${REAL_CC:=clang}"
: "${CFLAGS:=}"
: "${LDFLAGS:=}"
: "${LIBS:=}"
if printf ' %s ' "$*" | grep -q ' -c '; then
  exec ${REAL_CC} ${CFLAGS} "$@"
else
  exec ${REAL_CC} ${CFLAGS} "$@" ${LDFLAGS} ${LIBS}
fi
EOF
chmod +x "$REPO_ROOT/lmbench/scripts/compiler"

# sanitize Makefile
sed -i 's/--as-needed//g' "$REPO_ROOT/lmbench/src/Makefile" || true
sed -i -E 's|(../bin/[^ ]*/)getopt\.o|\1mygetopt.o|g' "$REPO_ROOT/lmbench/src/Makefile"
sed -i -E 's|(../bin/[^ ]*/)getopt\.o:|\1mygetopt.o:|g' "$REPO_ROOT/lmbench/src/Makefile"
grep -q 'mygetopt\.o' "$REPO_ROOT/lmbench/src/Makefile" || cat >> "$REPO_ROOT/lmbench/src/Makefile" <<'EOF'

../bin/x86_64-linux-gnu/mygetopt.o: getopt.c
	$(CC) $(CFLAGS) -c getopt.c -o ../bin/x86_64-linux-gnu/mygetopt.o
EOF

# build
make -C "$REPO_ROOT/lmbench/src" -j \
  CC="$REPO_ROOT/lmbench/scripts/compiler" REAL_CC="$REAL_CC" \
  CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LIBS"

