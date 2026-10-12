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

BENCH_CPU="${BENCH_CPU-0}"            # set BENCH_CPU= (empty) to run unpinned
REPEATS="${BENCH_REPEATS:-10}"
VERIFY_TIMEOUT="${BENCH_VERIFY_TIMEOUT:-60}"
PROFILE="${BENCH_PROFILE:-1}"         # set BENCH_PROFILE=0 to skip perf record

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
# Output helpers
# ----------------------------------------------------------------------

# Run a command with all of its output going to the build log.
# On failure, show the end of the log and stop.
run_logged() {
    if ! "$@" >>"$LOG" 2>&1; then
        echo "  FAILED: $*" >&2
        echo "  last lines of $LOG:" >&2
        tail -n 20 "$LOG" >&2
        exit 1
    fi
}

# Give a root-owned file back to the current user.
reclaim() {
    sudo chown "$(id -u):$(id -g)" "$@" 2>/dev/null || true
}


# ----------------------------------------------------------------------
# Build, stage, verify
# ----------------------------------------------------------------------

build_all() {
    echo "[build] native"
    run_logged "$COMPILE_DIR/build_native.sh" "$BENCH_ARG"

    echo "[build] wasm"
    run_logged "$COMPILE_DIR/build_wasm.sh" "$BENCH_ARG"

    echo "[build] lind"
    run_logged "$COMPILE_DIR/build_lind.sh" "$BENCH_ARG"
}

stage_lind() {
    echo "[stage] installing Lind benchmark"

    run_logged "$APPS_ROOT/scripts/post_install.sh" \
        "${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}" \
        "$BUILD_DIR" \
        stage
}

verify_lind() {
    echo "[verify] Lind guest"

    local rc=0
    timeout "$VERIFY_TIMEOUT" \
        "${PIN[@]}" \
        lind_run \
        --enable-fpcast \
        "/bin/$BENCH" >>"$LOG" 2>&1 || rc=$?

    if [[ "$rc" -eq 124 ]]; then
        die "Lind verification timed out after ${VERIFY_TIMEOUT}s (see $LOG)"
    elif [[ "$rc" -ne 0 ]]; then
        die "Lind verification failed with status $rc (see $LOG)"
    fi
}


# ----------------------------------------------------------------------
# perf stat
# ----------------------------------------------------------------------

# perf_stat <name> <plain|sudo> <command...>
#
# Statistics go to $RESULTS_DIR/<name>.stat.txt.
# Everything the benchmark itself prints goes to <name>.program.log.
perf_stat() {
    local name="$1" mode="$2"
    shift 2

    local out="$RESULTS_DIR/$name.stat.txt"
    local plog="$RESULTS_DIR/$name.program.log"
    local -a pre=()

    if [[ "$mode" == sudo ]]; then
        pre=(sudo -E)
        # root's PATH may not include lind_run, so pass the full path
        set -- "$(command -v "$1")" "${@:2}"
    fi

    echo "[stat] $name ($REPEATS runs)"

    if ! "${pre[@]}" perf stat \
            -r "$REPEATS" \
            -o "$out" \
            -- \
            "${PIN[@]}" \
            "$@" >"$plog" 2>&1
    then
        [[ "$mode" == sudo ]] && reclaim "$out"
        die "perf stat failed for $name (see $plog)"
    fi

    [[ "$mode" == sudo ]] && reclaim "$out"
    return 0
}


# ----------------------------------------------------------------------
# perf record
# ----------------------------------------------------------------------

# perf_profile <name> <plain|sudo> <command...>
#
# Raw samples go to $RESULTS_DIR/<name>.perf.data (binary, read with perf report).
# The readable report goes to $RESULTS_DIR/<name>.report.txt.
perf_profile() {
    local name="$1" mode="$2"
    shift 2

    local data="$RESULTS_DIR/$name.perf.data"
    local report="$RESULTS_DIR/$name.report.txt"
    local plog="$RESULTS_DIR/$name.record.log"
    local -a pre=()

    if [[ "$mode" == sudo ]]; then
        pre=(sudo -E)
        set -- "$(command -v "$1")" "${@:2}"
    fi

    echo "[profile] $name"

    if ! "${pre[@]}" perf record \
            -e "$PERF_EVENT" \
            --call-graph dwarf \
            -o "$data" \
            -- \
            "${PIN[@]}" \
            "$@" >"$plog" 2>&1
    then
        [[ "$mode" == sudo ]] && reclaim "$data"
        echo "  perf record failed for $name (see $plog), skipping" >&2
        return 0
    fi

    [[ "$mode" == sudo ]] && reclaim "$data"

    perf report -i "$data" --stdio >"$report" 2>>"$plog" ||
        echo "  perf report failed for $name (see $plog)" >&2
}


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

# Prints "<mean> <stddev>" in seconds from a perf stat output file.
elapsed_of() {
    awk '/seconds time elapsed/ { print $1, $3; exit }' "$1"
}

write_summary() {
    local summary="$RESULTS_DIR/summary.txt"
    local native_mean
    native_mean="$(elapsed_of "$RESULTS_DIR/native.stat.txt" | awk '{print $1}')"

    {
        echo "Benchmark : $BENCH"
        echo "Dataset   : $DATASET"
        echo "Opt level : -O$OPT_LEVEL"
        echo "Repeats   : $REPEATS"
        echo "CPU       : ${BENCH_CPU:-unpinned}"
        echo "Date      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        printf '%-10s %14s %12s %10s\n' "Config" "Elapsed (s)" "± (s)" "vs native"

        local name mean sd
        for name in native wasmtime lind; do
            read -r mean sd < <(elapsed_of "$RESULTS_DIR/$name.stat.txt")
            awk -v n="$name" -v m="$mean" -v s="$sd" -v b="$native_mean" \
                'BEGIN { printf "%-10s %14.6f %12.6f %9.2fx\n", n, m, s, m / b }'
        done
    } >"$summary"

    cat "$summary"
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

    # cpu_core/cycles/ only exists on Intel hybrid CPUs
    PERF_EVENT=cycles
    if perf list 2>/dev/null | grep -q 'cpu_core/cycles/'; then
        PERF_EVENT=cpu_core/cycles/
    fi

    RESULTS_DIR="$BUILD_DIR/results/$BENCH-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$RESULTS_DIR"
    LOG="$RESULTS_DIR/build.log"

    echo "Results: $RESULTS_DIR"
    echo

    build_all
    stage_lind
    verify_lind

    echo
    perf_stat native plain \
        "$INTERMEDIATES/$BENCH.native"

    perf_stat wasmtime plain \
        "$WASMTIME" run \
        --allow-precompiled \
        "$INTERMEDIATES/$BENCH.cwasm"

    # Start perf with privileges so counters survive lind_run's sudo transition.
    perf_stat lind sudo \
        lind_run \
        --enable-fpcast \
        "/bin/$BENCH"

    if [[ "$PROFILE" == 1 ]]; then
        echo
        perf_profile native plain \
            "$INTERMEDIATES/$BENCH.native"

        # --profile=perfmap lets perf report name the wasm functions
        perf_profile wasmtime plain \
            "$WASMTIME" run \
            --profile=perfmap \
            --allow-precompiled \
            "$INTERMEDIATES/$BENCH.cwasm"

        perf_profile lind sudo \
            lind_run \
            --enable-fpcast \
            "/bin/$BENCH"
    fi

    echo
    write_summary
    echo
    echo "Full statistics: $RESULTS_DIR/*.stat.txt"
    [[ "$PROFILE" == 1 ]] && echo "Profiles:        $RESULTS_DIR/*.report.txt"
    return 0
}

main "$@"
