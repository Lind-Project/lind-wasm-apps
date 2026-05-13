#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
    if [[ -d "${APPS_ROOT}/../lind-wasm/lindfs" ]]; then
        LIND_WASM_ROOT="$(cd "${APPS_ROOT}/../lind-wasm" && pwd)"
    else
        echo "[!] LIND_WASM_ROOT is not set and ../lind-wasm/lindfs was not found"
        exit 1
    fi
fi

LINDFS="${LIND_WASM_ROOT}/lindfs"
DATA_DIR="/pgdata-imfs"
SOCK_DIR="/sock"
RUN_SCRIPT="${LINDFS}/run_pg.sh"
GRATE_BIN="grates/fs-routing-clamp.cwasm"
IMFS_GRATE_BIN="grates/imfs-grate.cwasm"
CLAMP_ARGS=("--prefix" "${DATA_DIR}" "%{" "${IMFS_GRATE_BIN}" "%}")

usage() {
    cat <<EOF
Usage: $0

Runs Postgres through fs-routing-clamp with:
  data directory: ${DATA_DIR}
  socket dir:     ${SOCK_DIR}
  test runner:    pg_regress serial_schedule
  LindFS:         ${LINDFS}
EOF
}

cleanup() {
    echo "[*] Cleanup triggered..."
    sudo rm -f "${LINDFS}${SOCK_DIR}/.s.PGSQL.5432"* 2>/dev/null || true
    if [[ "${DATA_DIR}" != "/" && "${DATA_DIR}" == /* ]]; then
        sudo rm -rf "${LINDFS}${DATA_DIR}" 2>/dev/null || true
    fi
    sudo rm -f "${RUN_SCRIPT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[!] Unexpected argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ "${DATA_DIR}" != /* || "${SOCK_DIR}" != /* ]]; then
    echo "[!] DATA_DIR and SOCK_DIR must be absolute Lind paths"
    exit 1
fi

if [[ ! -f "${LINDFS}/${GRATE_BIN}" ]]; then
    echo "[!] Grate not found: ${LINDFS}/${GRATE_BIN}"
    echo "[!] Run make install from lind-wasm-example-grates or copy fs-routing-clamp.cwasm into lindfs/grates."
    exit 1
fi

if [[ ! -f "${LINDFS}/${IMFS_GRATE_BIN}" ]]; then
    echo "[!] Grate not found: ${LINDFS}/${IMFS_GRATE_BIN}"
    echo "[!] Run make install from lind-wasm-example-grates or copy imfs-grate.cwasm into lindfs/grates."
    exit 1
fi

for bin in initdb postgres psql pg_regress; do
    if [[ ! -f "${LINDFS}/bin/${bin}.cwasm" ]]; then
        echo "[!] Missing Lind binary: ${LINDFS}/bin/${bin}.cwasm"
        echo "[!] Run make install-postgres from lind-wasm-apps."
        exit 1
    fi
done

if [[ ! -f "${LINDFS}/regress/serial_schedule" ]]; then
    echo "[!] Missing pg_regress schedule: ${LINDFS}/regress/serial_schedule"
    echo "[!] Run make install-postgres from lind-wasm-apps."
    exit 1
fi

mkdir -p "${LINDFS}${SOCK_DIR}"

cat > "${RUN_SCRIPT}" <<EOF
#!/bin/bash
set -e

pg_pid=""

cleanup_inner() {
    if [ -n "\${pg_pid}" ]; then
        kill "\${pg_pid}" 2>/dev/null || true
        wait "\${pg_pid}" 2>/dev/null || true
    fi
}
trap cleanup_inner EXIT INT TERM

/bin/initdb.cwasm -D "${DATA_DIR}" \\
    -c max_parallel_workers=0 \\
    -c max_parallel_workers_per_gather=0 \\
    -c io_method=sync \\
    -c unix_socket_directories="${SOCK_DIR}"

/bin/postgres.cwasm -D "${DATA_DIR}" &
pg_pid=\$!

sleep 5

/bin/psql.cwasm -h "${SOCK_DIR}" -p 5432 -d postgres -c "CREATE DATABASE regression;"

cd /regress
/bin/pg_regress.cwasm --use-existing --host="${SOCK_DIR}" --port=5432 \\
    --bindir=/bin --inputdir=/regress --expecteddir=/regress \\
    --schedule=/regress/serial_schedule --max-concurrent-tests=1
EOF

chmod +x "${RUN_SCRIPT}"

echo "[*] Running Postgres inside Lind..."
echo "[*] DATA_DIR=${DATA_DIR}"
echo "[*] SOCK_DIR=${SOCK_DIR}"
echo "[*] REGRESS_SCHEDULE=/regress/serial_schedule"
echo "[*] LINDFS=${LINDFS}"

lind-wasm --enable-fpcast \
    "${GRATE_BIN}" \
    "${CLAMP_ARGS[@]}" \
    /bin/bash run_pg.sh
