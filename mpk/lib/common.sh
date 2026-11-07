#!/usr/bin/env bash
# Shared helpers for mpk/recipes/<app>.sh. Sourced by mpk/lib/stage.sh.
#
# Environment provided by assess.py:
#   APP            app name
#   APPS_ROOT      lind-wasm-apps checkout (read-only for recipes)
#   LIND_WASM_ROOT lind-wasm checkout (lind-boot, glibc, lindfs)
#   SRC            scratch copy of $APPS_ROOT/$APP (recipes build here)
#   NATIVE         lindfs-shaped output tree for *native* ELF programs, e.g.
#                  $NATIVE/usr/local/bin/sed; assess.py rewrites every ELF
#                  executable in it and installs the result into lindfs
#   PREFIX         install prefix for static dependency libraries (zlib, ...)
#   JOBS           parallel build jobs
#   SMOKE_TIMEOUT  per-command timeout (seconds) for smoke checks

set -euo pipefail

MPK_BIN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../bin" && pwd)"
export MPK_CC="$MPK_BIN/lind-mpk-cc"
export MPK_CXX="$MPK_BIN/lind-mpk-c++"
export CC="$MPK_CC" CXX="$MPK_CXX"
export CFLAGS="${MPK_CFLAGS:--O2 -g}"
export CXXFLAGS="${MPK_CXXFLAGS:--O2 -g}"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
LINDFS="$LIND_WASM_ROOT/lindfs"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-60}"

# Autotools trees are vendored with generated files; keep make from trying to
# rerun aclocal/automake/autoconf because of copy timestamps.
autotools_touch() {
  local f
  for f in aclocal.m4 configure Makefile.in config.h.in config_h.in; do
    find . -name "$f" -exec touch {} + 2>/dev/null || true
  done
}

# Native configure with lind-mpk wrappers. Extra args are passed through.
mpk_configure() {
  ./configure CC="$MPK_CC" CXX="$MPK_CXX" --prefix=/usr/local "$@"
}

# stage_bin <built file> <lindfs path>
stage_bin() {
  install -D -m 755 "$1" "$NATIVE/${2#/}"
}

# Smoke checks print one SMOKE PASS/FAIL/SKIP line each; assess.py counts them.
#
# smoke <name> <expected-substring|""> [--exit N] [--stdin FILE] -- <guest argv...>
#   Runs the guest program under lind-boot from /, inside the lindfs chroot.
smoke() {
  local name="$1" expect="$2"; shift 2
  local want_exit=0 stdin=/dev/null
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in
      --exit) want_exit="$2"; shift 2 ;;
      --stdin) stdin="$2"; shift 2 ;;
      *) echo "smoke: bad option $1" >&2; return 2 ;;
    esac
  done
  shift
  # Binaries whose rewrite failed are not installed; that is already reported.
  if [[ "$1" == /* && ! -e "$LINDFS$1" ]]; then
    echo "SMOKE SKIP: $name — $1 not installed (rewrite failed)"
    return 0
  fi
  local out rc=0
  out="$(cd "$LIND_WASM_ROOT" && timeout --kill-after=5 "$SMOKE_TIMEOUT" \
    "$LIND_WASM_ROOT/scripts/lind_run" "$@" <"$stdin" 2>&1)" || rc=$?
  printf -- '--- smoke %s: %s (exit %s)\n%s\n' "$name" "$*" "$rc" "$(printf '%s' "$out" | head -c 4000)"
  if [[ $rc == 124 || $rc == 137 ]]; then
    echo "SMOKE FAIL: $name — timeout after ${SMOKE_TIMEOUT}s"
  elif [[ $rc != "$want_exit" ]]; then
    echo "SMOKE FAIL: $name — exit $rc (want $want_exit): $(printf '%s' "$out" | grep -v '^\[lind' | tail -n 1 | head -c 200)"
  elif [[ -n "$expect" && "$out" != *"$expect"* ]]; then
    echo "SMOKE FAIL: $name — output lacks '$expect'"
  else
    echo "SMOKE PASS: $name"
  fi
}

# Guests run as root (lind_run uses sudo), so files they create in lindfs are
# root-owned; remove them with sudo.
lindfs_rm() {
  rm -rf -- "$@" 2>/dev/null || sudo -n rm -rf -- "$@"
}

# fresh_dir <lindfs path> : empty directory inside lindfs
fresh_dir() {
  lindfs_rm "$LINDFS/${1#/}"
  mkdir -p "$LINDFS/${1#/}"
}

# fixture <lindfs path> : write stdin to a file inside lindfs
fixture() {
  mkdir -p "$(dirname "$LINDFS/${1#/}")"
  lindfs_rm "$LINDFS/${1#/}"
  cat >"$LINDFS/${1#/}"
}
