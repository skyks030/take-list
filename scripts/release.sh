#!/bin/bash
# Veröffentlicht eine neue Version als GitHub-Release: scripts/release.sh 1.1.0 "Release-Notizen"
# Die App lädt beim Update das Asset Take-Liste-<Version>-macOS.zip herunter.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW="${1:?Version angeben, z. B. scripts/release.sh 1.1.0 \"Notizen\"}"
NOTES="${2:-Take-Liste $NEW}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Arbeitsverzeichnis ist nicht sauber – bitte erst committen." >&2; exit 1
fi

echo "$NEW" > VERSION
git add VERSION
git commit -m "Release $NEW" >/dev/null || true

./build.sh

mkdir -p dist
ZIP="dist/Take-Liste-$NEW-macOS.zip"
DMG="dist/Take-Liste-$NEW.dmg"
rm -f "$ZIP" "$DMG"
ditto -c -k --sequesterRsrc --keepParent "build/Take-Liste.app" "$ZIP"

STAGE=$(mktemp -d)
cp -R "build/Take-Liste.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Take-Liste $NEW" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

git tag "v$NEW"
git push origin HEAD --tags
gh release create "v$NEW" "$ZIP" "$DMG" --title "Take-Liste $NEW" --notes "$NOTES"
echo "✓ Release v$NEW veröffentlicht"
