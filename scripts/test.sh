#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
appname=${1:-${appname:-}}

[ -n "$appname" ] || {
  echo "usage: $0 <appname>"
  exit 1
}

expected_binaries="$repo_root/$appname/expected-binaries.txt"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$repo_root/build/$appname/$f" ] || {
    echo "missing: $repo_root/build/$appname/$f"
    exit 1
  }
done < "$expected_binaries"

echo "SUCCESS: All expected binaries present"
