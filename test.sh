#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${CUBASESHELF_BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR/module-cache"
swiftc -O -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  Source/Library.swift Source/Audio.swift Source/Tests.swift -o "$BUILD_DIR/CubaseShelfTests"
"$BUILD_DIR/CubaseShelfTests" "$@"
