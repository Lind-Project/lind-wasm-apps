#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------

POLYBENCH_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPILE_DIR="$POLYBENCH_ROOT/compile"
APPS_ROOT="$(cd "$POLYBENCH_ROOT/.." && pwd)"

source "$COMPILE_DIR/lib.sh"


# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------

BENCH_ARG="${1:-gemm}"

BENCH_CPU="${BENCH_CPU:-0}"
REPEATS="${BENCH_REPEATS:-10}"
VERIFY_TIMEOUT="${BENCH_VERIFY_TIMEOUT:-60}"

DATASET="${POLYBENCH_DATASET:-LARGE_DATASET}"
OPT_LEVEL="${POLYBENCH_OPT_LEVEL:-2}"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
WASMTIME="$HOME/tools/wasmtime-v44.0.0-x86_64-linux/wasmtime"

BUILD_DIR="$APPS_ROOT/build/polybench"
INTERMEDIATES="$BUILD_DIR/intermediates"


# ----------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------

validate_run() {
    [[ "$REPEATS" =~ ^[1-9][0-9]*$ ]] ||
        die "BENCH_REPEATS must be a positive integer"

    command -v perf >/dev/null ||
        die "perf not found"

    command -v taskset >/dev/null ||
        die "taskset not found"

    command -v timeout >/dev/null ||
        die "timeout not found"

    command -v "$WASMTIME" >/dev/null ||
        die "wasmtime not found: $WASMTIME"

    command -v lind_run >/dev/null ||
        die "lind_run not found"
}


# ----------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------

build_all() {
    echo
    echo "========================================"
    echo " Building PolyBench configurations"
    echo "========================================"

    "$COMPILE_DIR/build_native.sh" "$BENCH_ARG"

    echo
    "$COMPILE_DIR/build_wasm.sh" "$BENCH_ARG"

    echo
    "$COMPILE_DIR/build_lind.sh" "$BENCH_ARG"
}


# ----------------------------------------------------------------------
# Lind staging
# ----------------------------------------------------------------------

stage_lind() {
    echo
    echo "[stage] installing Lind benchmark"

    "$APPS_ROOT/scripts/post_install.sh" \
        "${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}" \
        "$BUILD_DIR" \
        stage
}


# ----------------------------------------------------------------------
# Lind verification
# ----------------------------------------------------------------------

verify_lind() {
    echo
    echo "[verify] Lind guest"

    if timeout "$VERIFY_TIMEOUT" \
        "${PIN[@]}" \
        lind_run \
        --enable-fpcast \
        "/bin/$BENCH"
    then
        echo "[verify] Lind completed successfully"
    else
        local rc=$?

        if [[ "$rc" -eq 124 ]]; then
            die "Lind verification timed out after ${VERIFY_TIMEOUT}s"
        fi

        die "Lind verification failed with status $rc"
    fi
}


# ----------------------------------------------------------------------
# perf helpers
# ----------------------------------------------------------------------

run_perf() {
    local label="$1"
    shift

    echo
    echo "========================================"
    echo " $label"
    echo "========================================"

    perf stat \
        -r "$REPEATS" \
        -- \
        "${PIN[@]}" \
        "$@"
}


run_perf_sudo() {
    local label="$1"
    shift

    echo
    echo "========================================"
    echo " $label"
    echo "========================================"

    sudo -E perf stat \
        -r "$REPEATS" \
        -- \
        "${PIN[@]}" \
        "$@"
}

run_perf_record() {
    local label="$1"
    local outfile="$2"
    shift 2

    echo
    echo "========================================"
    echo " Profiling: $label"
    echo "========================================"

    perf record \
        -e cpu_core/cycles/ \
        --call-graph dwarf \
        -o "$outfile" \
        -- \
        "${PIN[@]}" \
        "$@"

    echo
    echo "[profile] saved: $outfile"
    echo
    perf report \
        -i "$outfile" \
        --stdio
}


run_perf_record_sudo() {
    local label="$1"
    local outfile="$2"
    shift 2

    echo
    echo "========================================"
    echo " Profiling: $label"
    echo "========================================"

    sudo -E perf record \
        -e cpu_core/cycles/ \
        --call-graph dwarf \
        -o "$outfile" \
        -- \
        "${PIN[@]}" \
        "$@"

    echo
    echo "[profile] saved: $outfile"
    echo

    sudo perf report \
        -i "$outfile" \
        --stdio
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

main() {
    resolve_benchmark "$BENCH_ARG" "$POLYBENCH_ROOT"

    validate_dataset "$DATASET"
    validate_opt_level "$OPT_LEVEL"
    validate_run

    PIN=()

    if [[ -n "$BENCH_CPU" ]]; then
        PIN=(taskset -c "$BENCH_CPU")
    fi

    build_all
    stage_lind
    verify_lind

    echo
    echo "========================================"
    echo " PolyBench benchmark"
    echo "========================================"
    echo "Benchmark : $BENCH"
    echo "Dataset   : $DATASET"
    echo "Opt level : -O$OPT_LEVEL"
    echo "Repeats   : $REPEATS"
    echo "CPU       : ${BENCH_CPU:-unpinned}"

    run_perf \
        "Native ELF" \
        "$INTERMEDIATES/$BENCH.native"

    run_perf \
        "Wasmtime" \
        "$WASMTIME" run \
        --allow-precompiled \
        "$INTERMEDIATES/$BENCH.cwasm"

    # Start perf with privileges so counters survive lind_run's sudo transition.
    run_perf_sudo \
        "Lind" \
        lind_run \
        --enable-fpcast \
        "/bin/$BENCH"

    echo
    echo "========================================"
    echo " PolyBench profiling"
    echo "========================================"

    PROFILE_DIR="$BUILD_DIR/profiles"
    mkdir -p "$PROFILE_DIR"

    run_perf_record \
        "Native ELF" \
        "$PROFILE_DIR/$BENCH.native.perf.data" \
        "$INTERMEDIATES/$BENCH.native"

    run_perf_record \
        "Wasmtime" \
        "$PROFILE_DIR/$BENCH.wasmtime.perf.data" \
        "$WASMTIME" run \
        --allow-precompiled \
        "$INTERMEDIATES/$BENCH.cwasm"

    run_perf_record_sudo \
        "Lind" \
        "$PROFILE_DIR/$BENCH.lind.perf.data" \
        lind_run \
        --enable-fpcast \
        "/bin/$BENCH"
}

main "$@"
