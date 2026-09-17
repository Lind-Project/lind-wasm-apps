#!/usr/bin/env bash
set -euo pipefail

# Build in-toto-cli for lind-wasm. Stages to build/in-toto/usr/local/bin/.
#
# Same recipe as lind-wasm/scripts/bin/cargo-lind_compile, inlined so that
# wasm-opt and precompile errors are not hidden and the grate-only
# --export=pass_fptr_to_wt is dropped.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APPS_BUILD="$APPS_ROOT/build"
STAGE_DIR="$APPS_BUILD/in-toto"
TOOL_ENV="$APPS_BUILD/.toolchain.env"

# Default LIND_WASM_ROOT: nested layout first, then sibling layout.
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  if [[ -d "$APPS_ROOT/../src/glibc" ]]; then
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"
  else
    LIND_WASM_ROOT="$(cd "$APPS_ROOT/../lind-wasm" && pwd)"
  fi
fi
export LIND_WASM_ROOT

RUST_TOOLCHAIN="${LIND_RUST_TOOLCHAIN:-nightly-2026-02-11}"
LINKER="${LIND_WASM_LINKER:-$LIND_WASM_ROOT/scripts/bin/wasip1-clang.sh}"
LIND_WASM_OPT="$LIND_WASM_ROOT/scripts/bin/lind-wasm-opt"
LIND_BOOT="${LIND_BOOT:-$LIND_WASM_ROOT/build/lind-boot}"
SYSROOT="$LIND_WASM_ROOT/src/glibc/sysroot"
PROFILE="${PROFILE:-release}"

log() { echo "[in-toto] $*" >&2; }

# $CLANG from `make preflight` is optional.
if [[ -r "$TOOL_ENV" ]]; then
  # shellcheck disable=SC1090
  . "$TOOL_ENV"
fi
# CLANG may be the LLVM directory (dev image) or a binary.
if [[ -n "${CLANG:-}" && -d "$CLANG" && -x "$CLANG/bin/clang" ]]; then
  CLANG_BIN="$CLANG/bin/clang"
elif [[ -n "${CLANG:-}" && -x "$CLANG" ]]; then
  CLANG_BIN="$CLANG"
else
  CLANG_BIN="clang"
fi

[[ -x "$LINKER" ]]        || { log "ERROR: linker wrapper not found: $LINKER"; exit 1; }
[[ -x "$LIND_WASM_OPT" ]] || { log "ERROR: lind-wasm-opt not found: $LIND_WASM_OPT"; exit 1; }
[[ -x "$LIND_BOOT" ]]     || { log "ERROR: lind-boot not found: $LIND_BOOT (run 'make lind-boot' in lind-wasm)"; exit 1; }
[[ -r "$SYSROOT/lib/wasm32-wasi/crt1.o" ]] || { log "ERROR: lind sysroot missing at $SYSROOT (run 'make sysroot' in lind-wasm)"; exit 1; }
command -v cargo >/dev/null || { log "ERROR: cargo not on PATH"; exit 1; }
rustup run "$RUST_TOOLCHAIN" rustc --version >/dev/null 2>&1 \
  || { log "ERROR: rust toolchain $RUST_TOOLCHAIN not installed (rustup toolchain install $RUST_TOOLCHAIN --component rust-src)"; exit 1; }

mkdir -p "$STAGE_DIR/usr/local/bin"

# cargo flags (same as cargo-lind_compile)
export CARGO_TARGET_WASM32_WASIP1_LINKER="$LINKER"
export CARGO_TARGET_WASM32_WASIP1_RUSTFLAGS="\
-C link-self-contained=no \
-C target-feature=+crt-static,+atomics,+bulk-memory \
-C link-arg=-Wl,--import-memory \
-C link-arg=-Wl,--export-memory \
-C link-arg=-Wl,--shared-memory \
-C link-arg=-Wl,--max-memory=67108864 \
-C link-arg=-Wl,--export=__stack_pointer \
-C link-arg=-Wl,--export=__stack_low \
-C link-arg=-Wl,--export=__tls_base"

# C code in crates (ring) needs the same wasm features as the rest, or
# wasm-ld rejects --shared-memory.
export CC_wasm32_wasip1="$CLANG_BIN"
export AR_wasm32_wasip1="${AR_wasm32_wasip1:-$(dirname "$(command -v "$CLANG_BIN" || echo "$CLANG_BIN")")/llvm-ar}"
export CFLAGS_wasm32_wasip1="--target=wasm32-wasip1 -matomics -mbulk-memory -pthread ${CFLAGS_wasm32_wasip1:-}"

CARGO_PROFILE_FLAG=()
[[ "$PROFILE" == "release" ]] && CARGO_PROFILE_FLAG=(--release)

# lind overlay of the libc crate (see lind-wasm docs/contribute/compile-with-rust.md)
LIND_LIBC_DIR="${LIND_LIBC_DIR:-$LIND_WASM_ROOT/build/lind-libc}"
"$LIND_WASM_ROOT/scripts/rust/make_lind_libc.sh" "$LIND_LIBC_DIR" --patch-std "$RUST_TOOLCHAIN"
CARGO_CONFIG_ARGS=(--config "patch.crates-io.libc.path=\"$LIND_LIBC_DIR\"")

build_crate() {
  local crate_dir="$1" bin_name="$2"
  log "cargo build ($PROFILE) in $crate_dir"
  ( cd "$crate_dir" && cargo "+$RUST_TOOLCHAIN" "${CARGO_CONFIG_ARGS[@]}" build -Z build-std=std,panic_abort \
        --target wasm32-wasip1 "${CARGO_PROFILE_FLAG[@]}" )

  local wasm="$crate_dir/target/wasm32-wasip1/$PROFILE/$bin_name.wasm"
  [[ -f "$wasm" ]] || { log "ERROR: expected $wasm after cargo build"; exit 1; }

  local opt="$crate_dir/target/$bin_name.opt.wasm"
  local cwasm="$crate_dir/target/$bin_name.opt.cwasm"
  log "lind-wasm-opt --static $wasm"
  "$LIND_WASM_OPT" --static "$wasm" -o "$opt"
  log "lind-boot --precompile $opt"
  "$LIND_BOOT" --precompile "$opt"
  [[ -f "$cwasm" ]] || { log "ERROR: expected $cwasm after precompile"; exit 1; }

  install -m 0755 "$cwasm" "$STAGE_DIR/usr/local/bin/$bin_name"
  install -m 0644 "$opt"   "$STAGE_DIR/usr/local/bin/$bin_name.opt.wasm"
  log "staged $STAGE_DIR/usr/local/bin/$bin_name"
}

build_crate "$SCRIPT_DIR/in-toto-cli" in-toto-cli

log "done"
