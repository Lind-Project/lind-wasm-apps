#!/bin/bash
set -euo pipefail

LINDFS="${LIND_WASM_ROOT}/lindfs"
TMPDIR="${LINDFS}/tmp"
PGDATA="${TMPDIR}/pgdata"
RUN_SCRIPT="${LINDFS}/run_pg.sh"

GRATE_BIN=""

trap cleanup EXIT INT TERM

cleanup() {
    echo "[*] Cleanup triggered..."

    sudo rm -f "${TMPDIR}/.s.PGSQL.5432"* 2>/dev/null || true
    sudo rm -rf "${PGDATA}" 2>/dev/null || true
    sudo rm -f "${RUN_SCRIPT}" 2>/dev/null || true
}

validate_grate() {
    local name="$1"

    if [[ "$name" == "none" ]]; then
        return 0
    fi

    local path="${LINDFS}/grates/${name}-grate.cwasm"

    if [[ ! -f "$path" ]]; then
        echo "[!] Grate not found: $path"
        echo "[!] Available grates in ${LINDFS}/grates:"
        ls -1 "${LINDFS}/grates" 2>/dev/null || true
        exit 1
    fi

    GRATE_BIN="grates/${name}-grate.cwasm"
}

EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --grate)
            validate_grate "${2:-}"
            shift 2
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# -------------------------
# Host initdb
# -------------------------
echo "[*] Host initdb..."
lind-wasm --enable-fpcast /bin/initdb.cwasm -D /tmp/pgdata \
    -c max_parallel_workers=0 \
    -c max_parallel_workers_per_gather=0 \
    -c io_method=sync

# -------------------------
# Inner script stored in LINDFS
# -------------------------
cat > "${RUN_SCRIPT}" <<EOF
/bin/postgres.cwasm -D /tmp/pgdata &
pg_pid=\$!

sleep 5

/bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "SELECT 1;"

kill \$pg_pid
wait \$pg_pid
EOF

chmod +x "${RUN_SCRIPT}"

# -------------------------
# Run inside Lind (GRATE WRAPS HERE)
# -------------------------
echo "[*] Running inside Lind..."

if [[ -n "${GRATE_BIN}" ]]; then
    lind-wasm --enable-fpcast \
        "${GRATE_BIN}" \
        "${EXTRA_ARGS[@]}" \
        /bin/bash "${RUN_SCRIPT}"
else
    lind-wasm --enable-fpcast /bin/bash run_pg.sh
fi
