#!/usr/bin/env bash
set -euo pipefail

# Native PolyBench compilation

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
NATIVE_CC="${NATIVE_CC:-clang}"

BUILD_DIR="$APPS_ROOT/build/polybench"
INTERMEDIATES="$BUILD_DIR/intermediates"

POLYBENCH_C="$POLYBENCH_ROOT/utilities/polybench.c"

mkdir -p "$INTERMEDIATES"


# ----------------------------------------------------------------------
# Native-specific validation
# ----------------------------------------------------------------------

validate_native() {
    command -v "$NATIVE_CC" >/dev/null ||
        die "compiler not found: $NATIVE_CC"

    [[ -f "$POLYBENCH_C" ]] ||
        die "missing PolyBench utility source: $POLYBENCH_C"
}


# ----------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------

build_native() {
    local benchmark_c="$BENCH_DIR/$BENCH.c"
    local output="$INTERMEDIATES/$BENCH.native"

    [[ -f "$benchmark_c" ]] ||
        die "missing benchmark source: $benchmark_c"

    echo "========================================"
    echo " Native PolyBench build"
    echo "========================================"
    echo "Benchmark : $BENCH"
    echo "Source    : $benchmark_c"
    echo "Dataset   : $DATASET"
    echo "Opt level : -O$OPT_LEVEL"
    echo "Compiler  : $NATIVE_CC"
    echo "Output    : $output"
    echo

    run "$NATIVE_CC" \
        -O"$OPT_LEVEL" \
        -g \
        -D"$DATASET" \
        -I"$POLYBENCH_ROOT/utilities" \
        -I"$BENCH_DIR" \
        "$POLYBENCH_C" \
        "$benchmark_c" \
        -lm \
        -o "$output"

    echo
    echo "[native] built: $output"
}


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
    resolve_benchmark "$BENCH_ARG" "$POLYBENCH_ROOT"

    validate_dataset "$DATASET"
    validate_opt_level "$OPT_LEVEL"
    validate_native

    build_native
}

main "$@"