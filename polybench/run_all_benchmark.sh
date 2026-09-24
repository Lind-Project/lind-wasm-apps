BENCHMARKS=(
    2mm
    3mm
    adi
    atax
    bicg
    cholesky
    correlation
    covariance
    deriche
    doitgen
    durbin
    fdtd-2d
    floyd-warshall
    gemm
    gemver
    gesummv
    gramschmidt
    heat-3d
    jacobi-1d
    jacobi-2d
    lu
    ludcmp
    mvt
    nussinov
    seidel-2d
    symm
    syr2k
    syrk
    trisolv
    trmm
)

mkdir -p results

for bench in "${BENCHMARKS[@]}"; do
    echo "========================================"
    echo "Running $bench"
    echo "========================================"

    if BENCH_REPEATS="$REPEATS" \
        ./run_benchmark.sh "$bench" 2>&1 | tee "results/${bench}.log"
    then
        echo "[PASS] $bench"
    else
        echo "[FAIL] $bench"
        echo "$bench" >> results/failed.txt
    fi
done