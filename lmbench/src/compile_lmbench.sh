#!/bin/bash
set +e

CLANG="/home/lind/lind-wasm/clang+llvm-16.0.4-x86_64-linux-gnu-ubuntu-22.04/bin/clang"
WASM_OPT="/home/lind/lind-wasm/tools/binaryen/bin/wasm-opt"
WASMTIME="/home/lind/lind-wasm/src/wasmtime/target/debug/wasmtime"
SYSROOT="/home/lind/lind-wasm/src/glibc/sysroot"

SRC_DIR="/home/lind/lind-wasm/lind-wasm-apps/lmbench/src"
OUT_DIR="/home/lind/lind-wasm/lind-wasm-apps/lmbench/src/wasm-bin"

mkdir -p "$OUT_DIR"

fail_count=0
cfiles=$(find "$SRC_DIR" -maxdepth 1 -name "*.c" \
    ! -name "getopt.c" \
    ! -name "lat_usleep.c" \
    ! -name "lib_*.c")

for cfile in $cfiles; do
    base=$(basename "$cfile" .c)
    wasm_tmp="$SRC_DIR/$base.wasm"
    ofile="$OUT_DIR/$base.cwasm"

    echo "[*] Compiling $base.c → $ofile with clang -std=gnu89"

    "$CLANG" -std=gnu89 -pthread --target=wasm32-unknown-wasi --sysroot="$SYSROOT" \
        -Wl,--import-memory,--export-memory,--max-memory=67108864,--export=__stack_pointer,--export=__stack_low \
        "$cfile" -g -O0 -o "$wasm_tmp"

    if [ ! -f "$wasm_tmp" ]; then
        echo "Failed to compile $base.c (clang error)"
        ((fail_count++))
        continue
    fi

    "$WASM_OPT" --epoch-injection --asyncify -O2 --debuginfo "$wasm_tmp" -o "$wasm_tmp"

    "$WASMTIME" compile "$wasm_tmp" -o "$ofile"

    if [ ! -f "$ofile" ]; then
        echo "Failed to compile $base.wasm to $base.cwasm"
        ((fail_count++))
        continue
    fi

    rm -f "$wasm_tmp"
done

total_count=$(echo "$cfiles" | wc -l)
echo ""
echo "[📊] total number: $total_count"
echo "[❌] compile error number: $fail_count"
echo "[✓] all the compiled file in: $OUT_DIR"


