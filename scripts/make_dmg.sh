#!/bin/bash
# Builds Satsuma.app and packs it into a drag-to-install disk image: build/Satsuma-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

# Stage outside the (iCloud-synced) Desktop, like build_app.sh, so no xattrs end up in the image.
SCRATCH="$HOME/Library/Caches/Satsuma-build"
STAGE="$SCRATCH/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
./scripts/build_app.sh "$STAGE"
ln -s /Applications "$STAGE/Applications"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Satsuma.app/Contents/Info.plist")"
DMG="$SCRATCH/Satsuma-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Satsuma $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

mkdir -p build
rm -f "build/Satsuma-$VERSION.dmg"
cp "$DMG" "build/Satsuma-$VERSION.dmg"
rm -rf "$STAGE"
echo "Built build/Satsuma-$VERSION.dmg"
