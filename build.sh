#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${CUBASESHELF_APP_PATH:-$PWD/LIFELINE Shelf.app}"
BUILD_DIR="${CUBASESHELF_BUILD_DIR:-$PWD/.build}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  Source/ProjectMetadata.swift Source/Library.swift Source/Relocation.swift Source/DirectoryMonitor.swift Source/TruePeak.swift Source/Loudness.swift Source/Alignment.swift Source/ChannelLayout.swift Source/Theme.swift Source/Audio.swift Source/Store.swift Source/App.swift \
  -o "$APP/Contents/MacOS/CubaseShelf"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/LifelineIcon.icns "$APP/Contents/Resources/LifelineIcon.icns"
cp Resources/BrandLogo.png "$APP/Contents/Resources/BrandLogo.png"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
