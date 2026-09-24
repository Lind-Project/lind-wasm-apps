#!/usr/bin/env bash
set -euo pipefail

COMPILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLYBENCH_ROOT="$(cd "$COMPILE_DIR/.." && pwd)"
APPS_ROOT="$(cd "$POLYBENCH_ROOT/.." && pwd)"

source "$COMPILE_DIR/lib.sh"

BENCH_ARG="${1:-gemm}"

DATASET="${POLYBENCH_DATASET:-LARGE_DATASET}"
OPT_LEVEL="${POLYBENCH_OPT_LEVEL:-2}"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"

BUILD_DIR="$APPS_ROOT/build/polybench"
INTERMEDIATES="$BUILD_DIR/intermediates"
STAGE_DIR="$BUILD_DIR/stage/bin"

WASM_OPT="${WASM_OPT:-$LIND_WASM_ROOT/tools/binaryen/bin/wasm-opt}"
LIND_COMPILE="${LIND_COMPILE:-$LIND_WASM_ROOT/scripts/bin/lind_compile}"
LLVM_BIN="${LLVM_BIN:-$(ls -d "$LIND_WASM_ROOT"/clang+llvm-*/bin 2>/dev/null | head -n1)}"
LIND_SYSROOT="${LIND_SYSROOT:-$LIND_WASM_ROOT/src/glibc/sysroot}"
POLYBENCH_C="$POLYBENCH_ROOT/utilities/polybench.c"

mkdir -p "$INTERMEDIATES" "$STAGE_DIR"


validate_lind() {
    [[ -x "$LLVM_BIN/clang" ]] ||
        die "Lind clang not found: $LLVM_BIN/clang"

    [[ -f "$LIND_SYSROOT/lib/wasm32-wasi/lind_utils.o" ]] ||
        die "Lind sysroot missing lind_utils.o: $LIND_SYSROOT"

    [[ -x "$WASM_OPT" ]] ||
        die "wasm-opt not found: $WASM_OPT"

    [[ -x "$LIND_COMPILE" ]] ||
        die "lind_compile not found: $LIND_COMPILE"
}


build_lind_wasm() {
    echo "[1/3] Compiling static Lind Wasm"

    # Match lind_compile's static memory and runtime-export requirements.
    run "$LLVM_BIN/clang" \
        --target=wasm32-unknown-wasi \
        --sysroot="$LIND_SYSROOT" \
        -pthread -O"$OPT_LEVEL" -g \
        -D"$DATASET" \
        -I"$POLYBENCH_ROOT/utilities" \
        -I"$BENCH_DIR" \
        "$POLYBENCH_C" "$BENCH_DIR/$BENCH.c" \
        "$LIND_SYSROOT/lib/wasm32-wasi/lind_utils.o" \
        -Wl,--import-memory,--export-memory,--max-memory=67108864 \
        -Wl,--export=__stack_pointer,--export=__stack_low \
        -Wl,--export=__tls_base,--export=__wasm_init_tls \
        -lm -o "$INTERMEDIATES/$BENCH.lind.wasm"
}


instrument_lind_wasm() {
    local input="$INTERMEDIATES/$BENCH.lind.wasm"
    local output="$INTERMEDIATES/$BENCH.lind.opt.wasm"

    [[ -f "$input" ]] ||
        die "missing Lind Wasm: $input"

    echo "========================================"
    echo " Lind PolyBench build"
    echo "========================================"
    echo "Benchmark : $BENCH"
    echo "Input     : $input"
    echo "Opt level : -O$OPT_LEVEL"
    echo

    echo "[2/3] Applying Lind transforms"

    # The Lind Wasm is statically linked. Keep epoch and asyncify
    # globals inside the module; Lind supplies imported globals only for dylink.
    run "$WASM_OPT" \
        --enable-bulk-memory \
        --enable-threads \
        --epoch-injection \
        --asyncify \
        --fpcast-emu \
        -O"$OPT_LEVEL" \
        --debuginfo \
        "$input" \
        -o "$output"
}


precompile_lind() {
    local input="$INTERMEDIATES/$BENCH.lind.opt.wasm"
    local expected="${input%.wasm}.cwasm"
    local output="$INTERMEDIATES/$BENCH.lind.cwasm"

    echo
    echo "[3/3] Precompiling with Lind modified Wasmtime"

    run "$LIND_COMPILE" \
        --precompile-only \
        "$input"

    [[ -f "$expected" ]] ||
        die "expected Lind cwasm not produced: $expected"

    mv "$expected" "$output"
    cp "$output" "$STAGE_DIR/$BENCH"

    echo
    echo "[lind] built: $output"
    echo "[lind] staged: $STAGE_DIR/$BENCH"
}


main() {
    resolve_benchmark "$BENCH_ARG" "$POLYBENCH_ROOT"

    validate_dataset "$DATASET"
    validate_opt_level "$OPT_LEVEL"
    validate_lind

    build_lind_wasm
    instrument_lind_wasm
    precompile_lind
}

main "$@"
