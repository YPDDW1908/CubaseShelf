#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CUBASESHELF_BUILD_DIR:?Set an absolute scratch build directory}"
: "${CUBASESHELF_PERF_DIR:?Set an absolute disposable fixture directory}"
mkdir -p "$CUBASESHELF_BUILD_DIR/module-cache"
swiftc -O -swift-version 5 -module-cache-path "$CUBASESHELF_BUILD_DIR/module-cache" \
  Source/{ProjectMetadata,Library,Relocation,DirectoryMonitor,TruePeak,Loudness,Alignment,ChannelLayout,Theme,Audio,Store}.swift \
  Tools/PerformanceCheck.swift -o "$CUBASESHELF_BUILD_DIR/PerformanceCheck"
"$CUBASESHELF_BUILD_DIR/PerformanceCheck" "$CUBASESHELF_PERF_DIR"
