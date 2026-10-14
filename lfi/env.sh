# Shared environment for building the apps for the LFI sandbox (source me).
# LFI_ROOT: your clone of the lind-lfi repository, after its scripts/bootstrap.sh and a build of
# lfi-runtime (see lfi/README.md). LFI_TC / LFI_RT can be set individually instead.
if [ -z "${LFI_TC:-}" ] || [ -z "${LFI_RT:-}" ]; then
    : "${LFI_ROOT:?set LFI_ROOT to your lind-lfi checkout (or LFI_TC and LFI_RT)}"
fi
LFI_TC=${LFI_TC:-$LFI_ROOT/.toolchain/x86_64-lfi-clang}
LFI_RT=${LFI_RT:-$LFI_ROOT/lfi-runtime}
export PATH="$LFI_TC/lfi-bin:$LFI_TC/bin:$PATH"
APPS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=${BUILD:-$APPS_ROOT/build-lfi}
ROOTFS=$BUILD/rootfs                      # DESTDIR: becomes the cage's "/"
JOBS=${JOBS:-$(nproc)}
RUN=${RUN:-$LFI_RT/build/tools/lfi-3i-run/lfi-3i-run}
GRATES=${GRATES:-$LFI_RT/threei/grates/out}
export CC=x86_64_lfi-linux-musl-clang
export AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
export CFLAGS="${CFLAGS:--O2}" LDFLAGS="${LDFLAGS:--static-pie}"
# tools the docs/man targets want and the build machine does not have
export MAKEINFO=true HELP2MAN=true
