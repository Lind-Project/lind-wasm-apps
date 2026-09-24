#!/usr/bin/env bash

# Shared PolyBench helper functions


die() {
    echo "[polybench] ERROR: $*" >&2
    exit 1
}


run() {
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
    "$@"
}


resolve_benchmark() {
    local bench_arg="$1"
    local search_root="$2"

    if [[ "$bench_arg" == *.c ]]; then
        [[ -f "$bench_arg" ]] ||
            die "no such source: $bench_arg"

        BENCH_DIR="$(cd -- "$(dirname -- "$bench_arg")" && pwd)"
        BENCH="$(basename -- "$bench_arg" .c)"
        return
    fi

    BENCH="$bench_arg"

    shopt -s globstar nullglob
    local sources=("$search_root"/**/"$BENCH.c")
    shopt -u globstar nullglob

    [[ ${#sources[@]} -eq 1 ]] ||
        die "expected exactly one source for '$BENCH', found ${#sources[@]}"

    BENCH_DIR="$(dirname -- "${sources[0]}")"
}


validate_dataset() {
    local dataset="$1"

    case "$dataset" in
        MINI_DATASET|SMALL_DATASET|MEDIUM_DATASET|LARGE_DATASET|EXTRALARGE_DATASET)
            ;;
        *)
            die "invalid dataset: $dataset"
            ;;
    esac
}


validate_opt_level() {
    local opt_level="$1"

    case "$opt_level" in
        0|1|2|3|s)
            ;;
        *)
            die "optimization level must be 0, 1, 2, 3, or s"
            ;;
    esac
}