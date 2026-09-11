#!/usr/bin/env bash
# in-toto demo: keygen -> run write-code -> run package -> gen-layout -> verify,
# then tamper foo.py and expect verify to fail.
#   ./run_tests.sh --native   host build (cargo build)
#   ./run_tests.sh            lind build via lind_run (needs make in-toto + install-in-toto)
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -z "${LIND_WASM_ROOT:-}" ]]; then
  if [[ -d "$APPS_ROOT/../src/glibc" ]]; then LIND_WASM_ROOT="$(cd "$APPS_ROOT/.." && pwd)"; else LIND_WASM_ROOT="$(cd "$APPS_ROOT/../lind-wasm" && pwd)"; fi
fi
LINDFS="${LINDFS_ROOT:-$LIND_WASM_ROOT/lindfs}"
EXPIRES="2030-01-01T00:00:00Z"

MODE="lind"
[[ "${1:-}" == "--native" ]] && MODE="native"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()   { echo -e "  [${GREEN}PASS${NC}] $*"; pass=$((pass+1)); }
bad()  { echo -e "  [${RED}FAIL${NC}] $*"; fail=$((fail+1)); }

if [[ "$MODE" == "native" ]]; then
  BIN="$SCRIPT_DIR/in-toto-cli/target/debug/in-toto-cli"
  [[ -x "$BIN" ]] || ( cd "$SCRIPT_DIR/in-toto-cli" && cargo build ) || exit 1
  WORK_HOST="$(mktemp -d)"
  WORK_GUEST="$WORK_HOST"
  CLI=("$BIN")
else
  BIN_GUEST="/usr/local/bin/in-toto-cli"
  [[ -f "$LINDFS$BIN_GUEST" ]] || { echo "ERROR: $LINDFS$BIN_GUEST missing (make in-toto && make install-in-toto)"; exit 1; }
  WORK_GUEST="/tests/in-toto"
  WORK_HOST="$LINDFS$WORK_GUEST"
  rm -rf "$WORK_HOST"; mkdir -p "$WORK_HOST"
  # lind_run needs sudo; guest paths are chroot-relative.
  CLI=(sudo -E timeout -s KILL 120 "$LIND_WASM_ROOT/scripts/bin/lind_run" "$BIN_GUEST")
fi
mkdir -p "$WORK_HOST/links"
echo "[test] mode=$MODE workdir(host)=$WORK_HOST"

run() { "${CLI[@]}" "$@"; }

echo "[test] keygen"
run keygen "$WORK_GUEST/owner.pk8" "$WORK_GUEST/owner.pub.json" >/dev/null && \
run keygen "$WORK_GUEST/func.pk8"  "$WORK_GUEST/func.pub.json"  >/dev/null && \
  [[ -s "$WORK_HOST/owner.pk8" && -s "$WORK_HOST/func.pub.json" ]] && ok "keygen wrote keys" || bad "keygen"

echo "[test] step write-code"
printf 'print("hello in-toto")\n' > "$WORK_HOST/foo.py"
run run --name write-code --key "$WORK_GUEST/func.pk8" --out "$WORK_GUEST/links" \
    --products "$WORK_GUEST/foo.py" --lstrip "$WORK_GUEST/" >/dev/null \
  && ls "$WORK_HOST"/links/write-code.*.link >/dev/null 2>&1 && ok "write-code link written" || bad "write-code"

echo "[test] step package"
( cd "$WORK_HOST" && tar czf foo.tar.gz foo.py )
run run --name package --key "$WORK_GUEST/func.pk8" --out "$WORK_GUEST/links" \
    --materials "$WORK_GUEST/foo.py" --products "$WORK_GUEST/foo.tar.gz" --lstrip "$WORK_GUEST/" >/dev/null \
  && ls "$WORK_HOST"/links/package.*.link >/dev/null 2>&1 && ok "package link written" || bad "package"

echo "[test] gen-layout"
run gen-layout --key "$WORK_GUEST/owner.pk8" --step-key "$WORK_GUEST/func.pub.json" \
    --out "$WORK_GUEST/root.layout" --expires "$EXPIRES" >/dev/null \
  && grep -q '"_type": "layout"' "$WORK_HOST/root.layout" && ok "layout signed" || bad "gen-layout"

echo "[test] verify (expect VERIFIED)"
out=$(run verify --layout "$WORK_GUEST/root.layout" --key "$WORK_GUEST/owner.pub.json" --links "$WORK_GUEST/links" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *VERIFIED* && "$out" == *"product foo.tar.gz"* ]]; then ok "verify passed"; else bad "verify rc=$rc: $out"; fi

echo "[test] tamper foo.py then re-run package (expect FAILED)"
printf 'print("tampered")\n' > "$WORK_HOST/foo.py"
run run --name package --key "$WORK_GUEST/func.pk8" --out "$WORK_GUEST/links" \
    --materials "$WORK_GUEST/foo.py" --products "$WORK_GUEST/foo.tar.gz" --lstrip "$WORK_GUEST/" >/dev/null
out=$(run verify --layout "$WORK_GUEST/root.layout" --key "$WORK_GUEST/owner.pub.json" --links "$WORK_GUEST/links" 2>&1)
rc=$?
if [[ $rc -ne 0 && "$out" == *FAILED* ]]; then ok "tampered chain rejected"; else bad "tamper not detected rc=$rc: $out"; fi

echo "[test] artifacts kept in $WORK_HOST"
echo "[test] $pass passed, $fail failed"
[[ $fail -eq 0 ]]
