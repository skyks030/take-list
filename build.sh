#!/bin/bash
# Baut "Take-Liste.app" in ./build (Release, universal arm64 + x86_64).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Take-Liste.app"
echo "▸ Kompiliere …"
swift build -c release --arch arm64 --arch x86_64 --product TakeList
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TakeList"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Erzeuge App-Icon …"
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/AppIcon.iconset"
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "▸ Erstelle App-Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TakeList"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "✓ Fertig: $APP"
