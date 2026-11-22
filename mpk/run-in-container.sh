#!/usr/bin/env bash
# Host-side entry point: run mpk/assess.py inside a lind dev container.
#
#   mpk/run-in-container.sh [-c CONTAINER] [assess.py args...]
#   e.g. mpk/run-in-container.sh -c mybox --mode both --exclude gcc clang
#
# CONTAINER defaults to $MPK_CONTAINER, else the running container that
# bind-mounts this checkout. If the container mounts this checkout, assess.py
# runs on it directly and results land in mpk/results/ as usual. Otherwise this
# checkout (without .git/ and build/) is synced to /home/lind/lind-wasm-apps in
# the container and mpk/results/ is copied back afterwards.
set -euo pipefail

APPS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEST="${MPK_CONTAINER_APPS:-/home/lind/lind-wasm-apps}"
user="${MPK_CONTAINER_USER:-lind}"

mounts() {  # "<source> <destination>" for every bind mount of container $1
  docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$1"
}

CONTAINER="${MPK_CONTAINER:-}"
if [[ "${1:-}" == "-c" ]]; then CONTAINER="$2"; shift 2; fi
if [[ -z "$CONTAINER" ]]; then
  for c in $(docker ps --format '{{.Names}}'); do
    if mounts "$c" | grep -q "^$APPS_ROOT "; then CONTAINER="$c"; break; fi
  done
fi
if [[ -z "$CONTAINER" ]]; then
  echo "usage: $0 [-c CONTAINER] [assess.py args...] (or set MPK_CONTAINER)" >&2
  echo "running containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')" >&2
  exit 2
fi

args=""
[[ $# -gt 0 ]] && args="$(printf '%q ' "$@")"

mounted="$(mounts "$CONTAINER" | awk -v s="$APPS_ROOT" '$1 == s { print $2; exit }')"
if [[ -n "$mounted" ]]; then
  echo "[run-in-container] $CONTAINER mounts this checkout at $mounted; running there"
  exec docker exec -u "$user" -w "$mounted" "$CONTAINER" bash -lc "python3 mpk/assess.py $args"
fi

rev="$(git -C "$APPS_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$APPS_ROOT" status --porcelain -uno 2>/dev/null)" ]]; then rev="$rev+dirty"; fi

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
docker exec -u "$user" -w "$DEST" "$CONTAINER" bash -lc "python3 mpk/assess.py $args" || status=$?

tmp="$(mktemp -d)"
if docker exec "$CONTAINER" tar -C "$DEST/mpk/results" -cf - . | tar -C "$tmp" -xf -; then
  rm -rf "$APPS_ROOT/mpk/results"
  mv "$tmp" "$APPS_ROOT/mpk/results"
  echo "[run-in-container] report: $APPS_ROOT/mpk/results/"
else
  rm -rf "$tmp"
  echo "[run-in-container] no results to copy back" >&2
fi
exit $status
