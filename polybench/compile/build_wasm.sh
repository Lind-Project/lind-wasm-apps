#!/usr/bin/env bash
set -euo pipefail

# Build WASI Wasm for upstream Wasmtime. Lind uses its own libc and memory ABI,
# so build_lind.sh compiles the same benchmark sources separately.

COMPILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLYBENCH_ROOT="$(cd "$COMPILE_DIR/.." && pwd)"
APPS_ROOT="$(cd "$POLYBENCH_ROOT/.." && pwd)"

source "$COMPILE_DIR/lib.sh"


# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

BENCH_ARG="${1:-gemm}"

DATASET="${POLYBENCH_DATASET:-LARGE_DATASET}"
OPT_LEVEL="${POLYBENCH_OPT_LEVEL:-2}"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"

BUILD_DIR="$APPS_ROOT/build/polybench"
INTERMEDIATES="$BUILD_DIR/intermediates"

WASI_SDK_ROOT="${WASI_SDK_ROOT:-/opt/wasi-sdk}"
WASI_SYSROOT="${WASI_SYSROOT:-$WASI_SDK_ROOT/share/wasi-sysroot}"
WASI_CC="${WASI_CC:-$WASI_SDK_ROOT/bin/clang}"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
WASMTIME="$HOME/tools/wasmtime-v44.0.0-x86_64-linux/wasmtime"

POLYBENCH_C="$POLYBENCH_ROOT/utilities/polybench.c"

mkdir -p "$INTERMEDIATES"


# ----------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------

validate_wasm() {
    command -v "$WASI_CC" >/dev/null ||
        die "WASI clang not found: $WASI_CC (set WASI_SDK_ROOT or WASI_CC)"

    [[ -d "$WASI_SYSROOT" ]] ||
        die "WASI sysroot not found: $WASI_SYSROOT"

    [[ -x "$WASM_OPT" ]] ||
        die "wasm-opt not found: $WASM_OPT"

    command -v "$WASMTIME" >/dev/null ||
        die "wasmtime not found: $WASMTIME"

    [[ -f "$POLYBENCH_C" ]] ||
        die "missing PolyBench utility source: $POLYBENCH_C"
}


# ----------------------------------------------------------------------
# C -> upstream WASI Wasm
# ----------------------------------------------------------------------

build_wasm() {
    local benchmark_c="$BENCH_DIR/$BENCH.c"
    local output="$INTERMEDIATES/$BENCH.upstream.wasm"

    [[ -f "$benchmark_c" ]] ||
        die "missing benchmark source: $benchmark_c"

    echo "========================================"
    echo " Upstream Wasm PolyBench build"
    echo "========================================"
    echo "Benchmark : $BENCH"
    echo "Source    : $benchmark_c"
    echo "Dataset   : $DATASET"
    echo "Opt level : -O$OPT_LEVEL"
    echo "Compiler  : $WASI_CC"
    echo "Sysroot   : $WASI_SYSROOT"
    echo "Output    : $output"
    echo

    run "$WASI_CC" \
        --target=wasm32-wasip1 \
        --sysroot="$WASI_SYSROOT" \
        -D_WASI_EMULATED_PROCESS_CLOCKS \
        -O"$OPT_LEVEL" \
        -g \
        -D"$DATASET" \
        -I"$POLYBENCH_ROOT/utilities" \
        -I"$BENCH_DIR" \
        "$POLYBENCH_C" \
        "$benchmark_c" \
        -lm \
        -lwasi-emulated-process-clocks \
        -o "$output"

    echo
    echo "[wasm] upstream WASI artifact: $output"
}


# ----------------------------------------------------------------------
# Binaryen optimization for the plain Wasmtime path
# ----------------------------------------------------------------------

optimize_wasm() {
    local input="$INTERMEDIATES/$BENCH.upstream.wasm"
    local output="$INTERMEDIATES/$BENCH.wasmtime.opt.wasm"

    echo
    echo "[wasmtime] optimizing upstream Wasm"

    run "$WASM_OPT" \
        -O"$OPT_LEVEL" \
        --debuginfo \
        "$input" \
        -o "$output"
}


# ----------------------------------------------------------------------
# Upstream Wasmtime AOT compilation
# ----------------------------------------------------------------------

precompile_wasmtime() {
    local input="$INTERMEDIATES/$BENCH.wasmtime.opt.wasm"
    local output="$INTERMEDIATES/$BENCH.cwasm"

    echo
    echo "[wasmtime] precompiling with upstream Wasmtime"

    "$WASMTIME" --version

    run "$WASMTIME" compile \
        -O opt-level="$OPT_LEVEL" \
        -o "$output" \
        "$input"

    echo
    echo "[wasmtime] built: $output"
}


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
    resolve_benchmark "$BENCH_ARG" "$POLYBENCH_ROOT"

    validate_dataset "$DATASET"
    validate_opt_level "$OPT_LEVEL"
    validate_wasm

    build_wasm
    optimize_wasm
    precompile_wasmtime
}

main "$@"
