#!/bin/bash
set -euo pipefail

# PostgreSQL test with IMFS grate
# Everything runs in ONE grate session so IMFS state persists

LINDFS="${LIND_WASM_ROOT}/lindfs"
TMPDIR="${LINDFS}/tmp"

GRATE_NAME="${1:-imfs}"
GRATE_BIN="grates/${GRATE_NAME}-grate.cwasm"

echo "[*] IMFS Postgres Test"
echo "[*] LIND_WASM_ROOT: ${LIND_WASM_ROOT}"
echo "[*] Grate: ${GRATE_BIN}"

# Validate grate exists
if [[ ! -f "${LINDFS}/${GRATE_BIN}" ]]; then
    echo "[!] Grate not found: ${LINDFS}/${GRATE_BIN}"
    echo "[!] Available grates:"
    ls -1 "${LINDFS}/grates/"*.cwasm 2>/dev/null || echo "  (none)"
    exit 1
fi

# Validate required binaries
for bin in initdb.cwasm postgres.cwasm psql.cwasm bash.cwasm; do
    if [[ ! -f "${LINDFS}/bin/${bin}" ]]; then
        echo "[!] Missing binary: ${LINDFS}/bin/${bin}"
        exit 1
    fi
done

# Cleanup from previous runs
cleanup() {
    echo "[*] Cleanup..."
    sudo rm -f "${TMPDIR}/.s.PGSQL.5432"* 2>/dev/null || true
    sudo rm -rf "${TMPDIR}/pgdata" 2>/dev/null || true
}

trap cleanup EXIT INT TERM
cleanup

# Inner script content - runs entirely inside one grate session
# This keeps IMFS state persistent across initdb -> postgres -> psql
# Using bash -c since IMFS can't see files on the real filesystem
INNER_SCRIPT='
set -e

echo "[inner] Starting initdb..."
/bin/initdb.cwasm -D /tmp/pgdata --no-locale

echo "[inner] initdb complete, starting postgres..."
/bin/postgres.cwasm -D /tmp/pgdata &
pg_pid=$!

echo "[inner] Waiting for postgres to start (pid=$pg_pid)..."
sleep 5

echo "[inner] Running psql test..."
/bin/psql.cwasm -h /tmp -p 5432 -d postgres -c "SELECT 1 AS imfs_test;"

echo "[inner] Test complete, stopping postgres..."
kill $pg_pid 2>/dev/null || true
wait $pg_pid 2>/dev/null || true

echo "[inner] Done!"
'

# Preload shared libs into IMFS so exec'd binaries can find them
# Use chroot-relative paths (grate runs inside lind-wasm's chroot)
# Must use --env to pass env vars to WASM binary
PRELOADS="/lib/libc.cwasm:/lib/libm.cwasm"

echo "[*] Running everything inside grate..."
echo "[*] PRELOADS: ${PRELOADS}"
echo "[*] Command: lind-wasm --enable-fpcast --env PRELOADS=... /${GRATE_BIN} /bin/bash.cwasm -c '...'"

lind-wasm --enable-fpcast \
    --env "PRELOADS=${PRELOADS}" \
    "/${GRATE_BIN}" \
    /bin/bash.cwasm -c "$INNER_SCRIPT"

echo "[*] Test finished!"
