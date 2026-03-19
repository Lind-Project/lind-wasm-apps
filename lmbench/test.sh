#!/bin/sh
set -eu

cd "$(dirname "$0")"
dir=../build/lmbench/bin

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$dir/$f" ] || { echo "missing: $dir/$f"; exit 1; }
done < expected-binaries.txt

echo "SUCCESS: All expected binaries present"