#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${CUBASESHELF_BUILD_DIR:-$PWD/.build}"
mkdir -p "$BUILD_DIR/module-cache"
swiftc -O -swift-version 5 -module-cache-path "$BUILD_DIR/module-cache" \
  Source/ProjectMetadata.swift Source/Library.swift Source/Relocation.swift Source/DirectoryMonitor.swift Source/TruePeak.swift Source/Loudness.swift Source/Alignment.swift Source/ChannelLayout.swift Source/Theme.swift Source/Audio.swift Source/Store.swift Source/AdvancedTests.swift Source/AlignmentTests.swift Source/EnhancementTests.swift Source/Tests.swift -o "$BUILD_DIR/CubaseShelfTests"
"$BUILD_DIR/CubaseShelfTests" "$@"
