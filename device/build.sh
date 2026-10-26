#!/bin/bash
# Build the native helpers (Swift + IOKit, no dependencies).
set -euo pipefail
cd "$(dirname "$0")"
for src in hidprobe hidreader; do
  echo "building $src"
  swiftc -O -framework IOKit -framework CoreFoundation "$src.swift" -o "$src"
done
