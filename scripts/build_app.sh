#!/bin/bash
# Builds Satsuma.app (release) into ./build and signs it ad hoc for local use.
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the (iCloud-synced) Desktop: synced folders add xattrs that codesign rejects.
SCRATCH="$HOME/Library/Caches/Satsuma-build"
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Satsuma"
APP="$SCRATCH/Satsuma.app"
DEST="${1:-build}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Satsuma"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.satsuma.app</string>
    <key>CFBundleName</key><string>Satsuma</string>
    <key>CFBundleDisplayName</key><string>Satsuma</string>
    <key>CFBundleExecutable</key><string>Satsuma</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSAppleEventsUsageDescription</key><string>Satsuma uses Pages, Keynote and Numbers to read and write iWork and Office formats.</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
mkdir -p "$DEST"
rm -rf "$DEST/Satsuma.app"
ditto "$APP" "$DEST/Satsuma.app"
echo "Built $DEST/Satsuma.app"
