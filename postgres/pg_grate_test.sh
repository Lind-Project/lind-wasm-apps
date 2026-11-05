#!/bin/bash
set -euo pipefail

# ============================================================
# Usage:
#   pg_grate-test.sh --test <connectivity|regress> [--grate <name>] [extra args...]
#
# --test connectivity   Run a simple SELECT 1 connectivity check
# --test regress        Run the full pg_regress suite
# --grate <name>        Wrap execution with a named grate
#                         Special values:
#                           none         no grate (default)
#                           clamp        use fs-routing-clamp + imfs composed
#                           <other>      looks for grates/<name>-grate.cwasm
#
# Examples:
#   pg_grate-test.sh --test connectivity
#   pg_grate-test.sh --test regress
#   pg_grate-test.sh --test regress --grate clamp
#   pg_grate-test.sh --test connectivity --grate my-custom
# ============================================================

# -------------------------
# Resolve paths
# -------------------------
APPS_ROOT="${HOME}/lind-wasm-apps"
LIND_WASM_ROOT="${LIND_WASM_ROOT:-${HOME}/lind-wasm}"

LINDFS="${LIND_WASM_ROOT}/lindfs"
RUN_SCRIPT="${LINDFS}/run_pg.sh"

# -------------------------
# Defaults
# -------------------------
TEST_TYPE=""
GRATE_NAME="none"
GRATE_BIN=""
EXTRA_ARGS=()

# clamp-specific config
CLAMP_DATA_DIR="/pgdata-imfs"
CLAMP_SOCK_DIR="/sock"
CLAMP_GRATE_BIN="grates/fs-routing-clamp.cwasm"
CLAMP_IMFS_GRATE_BIN="grates/imfs-grate.cwasm"

# standard (non-clamp) config
STD_TMPDIR="${LINDFS}/tmp"
STD_PGDATA="${STD_TMPDIR}/pgdata"

# -------------------------
# Cleanup
# -------------------------
cleanup() {
    echo "[*] Cleanup triggered..."

    if [[ "${GRATE_NAME}" == "clamp" ]]; then
        sudo rm -f "${LINDFS}${CLAMP_SOCK_DIR}/.s.PGSQL.5432"* 2>/dev/null || true
        if [[ "${CLAMP_DATA_DIR}" != "/" && "${CLAMP_DATA_DIR}" == /* ]]; then
            sudo rm -rf "${LINDFS}${CLAMP_DATA_DIR}" 2>/dev/null || true
        fi
    else
        sudo rm -f "${STD_TMPDIR}/.s.PGSQL.5432"* 2>/dev/null || true
        sudo rm -rf "${STD_PGDATA}" 2>/dev/null || true
    fi

    sudo rm -f "${RUN_SCRIPT}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# -------------------------
# Helpers
# -------------------------
usage() {
    cat <<EOF
Usage: $0 --test <connectivity|regress> [--grate <name|none|clamp>] [extra lind-wasm args...]

  --test connectivity   SELECT 1 connectivity check
  --test regress        Full pg_regress suite
  --grate none          No grate wrapper (default)
  --grate clamp         fs-routing-clamp + imfs-grate composed
  --grate <name>        Custom grate: grates/<name>-grate.cwasm must exist in lindfs

Environment:
  LIND_WASM_ROOT        Path to lind-wasm checkout (auto-detected if unset)
EOF
}

run_cmd() {
    # Run a command, print it, and emit a clear error if it fails
    echo "[>] ${*}"
    if ! "$@"; then
        echo ""
        echo "[!] Command failed: ${*}"
        echo "[!] Exit code: $?"
        exit 1
    fi
}

validate_grate_standard() {
    local name="$1"
    if [[ "$name" == "none" ]]; then
        GRATE_BIN=""
        return 0
    fi
    local path="${LINDFS}/grates/${name}-grate.cwasm"
    if [[ ! -f "$path" ]]; then
        echo "[!] Grate not found: $path"
        echo "[!] Available grates in ${LINDFS}/grates:"
        ls -1 "${LINDFS}/grates" 2>/dev/null || echo "    (directory empty or missing)"
        exit 1
    fi
    GRATE_BIN="grates/${name}-grate.cwasm"
}

validate_clamp_prerequisites() {
    if [[ ! -f "${LINDFS}/${CLAMP_GRATE_BIN}" ]]; then
        echo "[!] Clamp grate not found: ${LINDFS}/${CLAMP_GRATE_BIN}"
        echo "[!] Run: make install from lind-wasm-example-grates, or copy fs-routing-clamp.cwasm into lindfs/grates/"
        exit 1
    fi

    if [[ ! -f "${LINDFS}/${CLAMP_IMFS_GRATE_BIN}" ]]; then
        echo "[!] IMFS grate not found: ${LINDFS}/${CLAMP_IMFS_GRATE_BIN}"
        echo "[!] Run: make install from lind-wasm-example-grates, or copy imfs-grate.cwasm into lindfs/grates/"
        exit 1
    fi

    if [[ "${CLAMP_DATA_DIR}" != /* || "${CLAMP_SOCK_DIR}" != /* ]]; then
        echo "[!] CLAMP_DATA_DIR and CLAMP_SOCK_DIR must be absolute Lind paths"
        exit 1
    fi
}

validate_standard_binaries() {
    local bins=("initdb" "postgres" "psql")
    if [[ "${TEST_TYPE}" == "regress" ]]; then
        bins+=("pg_regress")
    fi

    for bin in "${bins[@]}"; do
        if [[ ! -f "${LINDFS}/bin/${bin}.cwasm" ]]; then
            echo "[!] Missing Lind binary: ${LINDFS}/bin/${bin}.cwasm"
            echo "[!] Run: make install-postgres from lind-wasm-apps"
            exit 1
        fi
    done
}

validate_regress_schedule() {
    if [[ ! -f "${LINDFS}/regress/serial_schedule" ]]; then
        echo "[!] Missing pg_regress schedule: ${LINDFS}/regress/serial_schedule"
        echo "[!] Run: make install-postgres from lind-wasm-apps"
        exit 1
    fi
}

# -------------------------
# Argument parsing
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            TEST_TYPE="${2:-}"
            if [[ "${TEST_TYPE}" != "connectivity" && "${TEST_TYPE}" != "regress" ]]; then
                echo "[!] Unknown test type: '${TEST_TYPE}'. Must be 'connectivity' or 'regress'."
                usage
                exit 1
            fi
            shift 2
            ;;
        --grate)
            GRATE_NAME="${2:-}"
            if [[ -z "${GRATE_NAME}" ]]; then
                echo "[!] --grate requires a value (none | clamp | <name>)"
                usage
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# -------------------------
# Validate required flags
# -------------------------
if [[ -z "${TEST_TYPE}" ]]; then
    echo "[!] --test is required."
    usage
    exit 1
fi

# -------------------------
# Pre-flight checks
# -------------------------
echo "[*] Test type : ${TEST_TYPE}"
echo "[*] Grate     : ${GRATE_NAME}"
echo "[*] LINDFS    : ${LINDFS}"

if [[ "${GRATE_NAME}" == "clamp" ]]; then
    # clamp path: all binaries run *inside* Lind (initdb included)
    validate_clamp_prerequisites

    for bin in initdb postgres psql; do
        if [[ ! -f "${LINDFS}/bin/${bin}.cwasm" ]]; then
            echo "[!] Missing Lind binary: ${LINDFS}/bin/${bin}.cwasm"
            echo "[!] Run: make install-postgres from lind-wasm-apps"
            exit 1
        fi
    done

    if [[ "${TEST_TYPE}" == "regress" ]]; then
        if [[ ! -f "${LINDFS}/bin/pg_regress.cwasm" ]]; then
            echo "[!] Missing Lind binary: ${LINDFS}/bin/pg_regress.cwasm"
            echo "[!] Run: make install-postgres from lind-wasm-apps"
            exit 1
        fi
        validate_regress_schedule
    fi

    mkdir -p "${LINDFS}${CLAMP_SOCK_DIR}"
else
    # standard path: initdb runs on host, rest inside Lind
    validate_grate_standard "${GRATE_NAME}"
    validate_standard_binaries

    if [[ "${TEST_TYPE}" == "regress" ]]; then
        validate_regress_schedule
    fi
fi

# -------------------------
# Build inner run script
# -------------------------

if [[ "${GRATE_NAME}" == "clamp" ]]; then
    # clamp: initdb also runs inside Lind; data dir and socket are Lind-internal paths
    if [[ "${TEST_TYPE}" == "connectivity" ]]; then
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

echo "[*] initdb (inside Lind, clamp)..."
/bin/initdb.cwasm -D "${CLAMP_DATA_DIR}" \\
    -c max_parallel_workers=0 \\
    -c max_parallel_workers_per_gather=0 \\
    -c io_method=sync \\
    -c unix_socket_directories="${CLAMP_SOCK_DIR}" \\
    || { echo "[!] initdb failed"; exit 1; }

echo "[*] Starting postgres..."
/bin/postgres.cwasm -D "${CLAMP_DATA_DIR}" &
pg_pid=\$!

echo "[*] Waiting for Postgres startup..."
sleep 5

echo "[*] Running connectivity check..."
/bin/psql.cwasm -h "${CLAMP_SOCK_DIR}" -p 5432 -d postgres -c "SELECT 1;" \\
    || { echo "[!] Connectivity check failed"; exit 1; }

echo "[*] Connectivity check passed."
EOF

    else  # regress
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

echo "[*] initdb (inside Lind, clamp)..."
/bin/initdb.cwasm -D "${CLAMP_DATA_DIR}" \\
    -c max_parallel_workers=0 \\
    -c max_parallel_workers_per_gather=0 \\
    -c io_method=sync \\
    -c unix_socket_directories="${CLAMP_SOCK_DIR}" \\
    || { echo "[!] initdb failed"; exit 1; }

echo "[*] Starting postgres..."
/bin/postgres.cwasm -D "${CLAMP_DATA_DIR}" &
pg_pid=\$!

echo "[*] Waiting for Postgres startup..."
sleep 5

echo "[*] Creating regression database..."
/bin/psql.cwasm -h "${CLAMP_SOCK_DIR}" -p 5432 -d postgres -v ON_ERROR_STOP=1 \\
    -c "CREATE DATABASE regression;" \\
    || { echo "[!] Failed to create regression database"; exit 1; }

echo "[*] Running pg_regress..."
cd /regress
/bin/pg_regress.cwasm --use-existing --host="${CLAMP_SOCK_DIR}" --port=5432 \\
    --bindir=/bin --inputdir=/regress --expecteddir=/regress \\
    --schedule=/regress/serial_schedule --max-concurrent-tests=1 \\
    || { echo "[!] pg_regress failed"; exit 1; }

echo "[*] Regression tests passed."
EOF
    fi

else
    # standard path: initdb is run on host before entering Lind
    if [[ "${TEST_TYPE}" == "connectivity" ]]; then
        cat > "${RUN_SCRIPT}" <<EOF
/bin/postgres.cwasm -D /tmp/pgdata &
pg_pid=\$!

sleep 5

echo "[*] Running connectivity check..."
/bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "SELECT 1;" \\
    || { echo "[!] Connectivity check failed"; exit 1; }

echo "[*] Connectivity check passed."

kill \$pg_pid
wait \$pg_pid
EOF

    else  # regress
        cat > "${RUN_SCRIPT}" <<EOF
/bin/postgres.cwasm -D /tmp/pgdata &
pg_pid=\$!

sleep 5

echo "[*] Creating regression database..."
/bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "CREATE DATABASE regression;" \\
    || { echo "[!] Failed to create regression database"; exit 1; }

echo "[*] Running pg_regress..."
/bin/pg_regress.cwasm --use-existing --host=/tmp --port=5432 \\
    --bindir=/bin --inputdir=/regress --expecteddir=/regress \\
    --schedule=/regress/serial_schedule --max-concurrent-tests=1 \\
    || { echo "[!] pg_regress failed"; exit 1; }

echo "[*] Regression tests passed."

kill \$pg_pid
wait \$pg_pid
EOF
    fi
fi

chmod +x "${RUN_SCRIPT}"

# -------------------------
# Host-side initdb (standard path only)
# -------------------------
if [[ "${GRATE_NAME}" != "clamp" ]]; then
    echo "[*] Running host initdb..."
    run_cmd lind-wasm --enable-fpcast /bin/initdb.cwasm -D /tmp/pgdata \
        -c max_parallel_workers=0 \
        -c max_parallel_workers_per_gather=0 \
        -c io_method=sync
fi

# -------------------------
# Launch inside Lind
# -------------------------
echo "[*] Launching inside Lind..."
echo "[*] DATA_DIR : $( [[ "${GRATE_NAME}" == "clamp" ]] && echo "${CLAMP_DATA_DIR}" || echo "/tmp/pgdata" )"
echo "[*] SOCK_DIR : $( [[ "${GRATE_NAME}" == "clamp" ]] && echo "${CLAMP_SOCK_DIR}" || echo "/tmp" )"

if [[ "${GRATE_NAME}" == "clamp" ]]; then
    CLAMP_ARGS=("--prefix" "${CLAMP_DATA_DIR}" "%{" "${CLAMP_IMFS_GRATE_BIN}" "%}")
    run_cmd lind-wasm --enable-fpcast \
        "${CLAMP_GRATE_BIN}" \
        "${CLAMP_ARGS[@]}" \
        /bin/bash run_pg.sh

elif [[ -n "${GRATE_BIN}" ]]; then
    run_cmd lind-wasm --enable-fpcast \
        "${GRATE_BIN}" \
        "${EXTRA_ARGS[@]}" \
        /bin/bash run_pg.sh

else
    run_cmd lind-wasm --enable-fpcast /bin/bash run_pg.sh
fi
