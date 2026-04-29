#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Build and test coreutils natively with the same configure options as the
# Lind WASM build. Useful for getting a native baseline of test pass/fail
# results to compare against the Lind runtime.
#
# Usage:
#   ./coreutils/build_and_test_native.sh
#
# Results saved to: build/coreutils-native-results.log
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COREUTILS_ROOT="$APPS_ROOT/coreutils"
RESULTS_LOG="$APPS_ROOT/build/coreutils-native-results.log"

mkdir -p "$APPS_ROOT/build"

cd "$COREUTILS_ROOT"

echo "[coreutils-native] cleaning previous build..."
make distclean >/dev/null 2>&1 || true

# Patch gnulib files that fail on modern glibc (coreutils 8.3 bundles old gnulib
# that doesn't recognize newer stdio internals)
echo "[coreutils-native] patching gnulib for modern glibc..."
grep -rl '#error "Please port gnulib' lib/ | while read -r f; do
  sed -i 's/#error "Please port gnulib.*"/return 0;/' "$f"
  echo "  patched: $f"
done

# Configure with the same options as the WASM build (minus cross-compile flags)
echo "[coreutils-native] configuring..."
./configure \
  --disable-shared \
  --enable-static \
  --disable-libtool-lock \
  --without-selinux \
  --without-libcap \
  CFLAGS="-O2 -g"

echo "[coreutils-native] building..."
make -j"$(nproc 2>/dev/null || echo 4)"

echo "[coreutils-native] running test suite..."
make check 2>&1 | tee "$RESULTS_LOG"

echo
echo "[coreutils-native] results saved to: $RESULTS_LOG"
echo "[coreutils-native] test-suite.log at: $COREUTILS_ROOT/tests/test-suite.log"
