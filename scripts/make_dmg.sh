#!/bin/bash
# Builds Satsuma.app and packs it into a drag-to-install disk image: build/Satsuma-<version>.dmg.
# The window gets Satsuma's own background (scripts/dmg_background.swift), 128 pt icons and fixed
# positions. dmgbuild writes the layout straight into the image, so Finder and Automation aren't needed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Stage outside the (iCloud-synced) Desktop, like build_app.sh, so no xattrs end up in the image.
SCRATCH="$HOME/Library/Caches/Satsuma-build"
STAGE="$SCRATCH/dmg-stage"
VENV="$SCRATCH/dmgbuild-venv"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# dmgbuild (pinned) lives in its own venv in the cache, never in the project.
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check "dmgbuild==1.6.7"
fi

./scripts/build_app.sh "$STAGE"

# Background: 1× and 2× in one multi-resolution TIFF, so it stays sharp on Retina screens.
swift scripts/dmg_background.swift "$STAGE/bg.png" "$STAGE/bg@2x.png"
tiffutil -cathidpicheck "$STAGE/bg.png" "$STAGE/bg@2x.png" -out "$STAGE/background.tiff" >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Satsuma.app/Contents/Info.plist")"
DMG="$SCRATCH/Satsuma-$VERSION.dmg"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg_settings.py \
    -D app="$STAGE/Satsuma.app" \
    -D background="$STAGE/background.tiff" \
    -D icon="$PWD/Resources/AppIcon.icns" \
    "Satsuma" "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

mkdir -p build
rm -f "build/Satsuma-$VERSION.dmg"
cp "$DMG" "build/Satsuma-$VERSION.dmg"
rm -rf "$STAGE"
echo "Built build/Satsuma-$VERSION.dmg"
