#!/usr/bin/env bash
# Host-side entry point: run the lind-mpk assessment inside a lind dev container
# that does not bind-mount lind-wasm-apps.
#
#   mpk/run-in-container.sh [-c CONTAINER] [assess.py args...]
#
# Syncs this checkout (without .git/ and build/) to /home/lind/lind-wasm-apps
# in the container, runs mpk/assess.py there, and copies mpk/results/ back.
# If the container already mounts the repo, just run mpk/assess.py inside it.
set -euo pipefail

CONTAINER="${MPK_CONTAINER:-cranky_keldysh}"
if [[ "${1:-}" == "-c" ]]; then CONTAINER="$2"; shift 2; fi
DEST="${MPK_CONTAINER_APPS:-/home/lind/lind-wasm-apps}"
APPS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

rev="$(git -C "$APPS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$APPS_ROOT" status --porcelain -uno 2>/dev/null)" ]]; then rev="$rev+dirty"; fi
user="${MPK_CONTAINER_USER:-lind}"

echo "[run-in-container] syncing $APPS_ROOT ($rev) -> $CONTAINER:$DEST"
docker exec "$CONTAINER" mkdir -p "$DEST"
tar -C "$APPS_ROOT" --exclude=./.git --exclude=./build --exclude=./mpk/results -cf - . \
  | docker exec -i "$CONTAINER" tar -C "$DEST" --keep-newer-files -xf - 2>/dev/null || true
# mpk/ is small and edited often; always refresh it exactly.
tar -C "$APPS_ROOT" --exclude=./mpk/results -cf - ./mpk \
  | docker exec -i "$CONTAINER" tar -C "$DEST" -xf -
docker exec "$CONTAINER" bash -c "printf '%s\n' '$rev' > '$DEST/.mpk-source-rev'"
docker exec -u root "$CONTAINER" chown -R "$user:$user" "$DEST"

status=0
args=""
[[ $# -gt 0 ]] && args="$(printf '%q ' "$@")"
docker exec -u "$user" -w "$DEST" "$CONTAINER" bash -lc \
  "python3 mpk/assess.py $args" || status=$?

rm -rf "$APPS_ROOT/mpk/results"
mkdir -p "$APPS_ROOT/mpk/results"
docker exec "$CONTAINER" tar -C "$DEST/mpk/results" -cf - . | tar -C "$APPS_ROOT/mpk/results" -xf - \
  || echo "[run-in-container] no results to copy back" >&2
echo "[run-in-container] report: $APPS_ROOT/mpk/results/report.md"
exit $status
