#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

BUILD_SCRATCH="/tmp/clamshell-dmg-build"
DIST_DIR="$SCRIPT_DIR/dist"
STAGING_DIR="/tmp/clamshell-dmg-staging"
APP_BUNDLE="$STAGING_DIR/Clamshell.app"
DMG_PATH="$DIST_DIR/Clamshell.dmg"

echo "🔨 Building Apple Silicon (arm64) CLI & Menu Bar App..."
swift build -c release --build-system native --scratch-path "$BUILD_SCRATCH" --arch arm64

mkdir -p "$SCRIPT_DIR/bin" "$DIST_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "📦 Packaging native arm64 binaries..."
cp "$BUILD_SCRATCH/arm64-apple-macosx/release/clamshell" "$SCRIPT_DIR/bin/clamshell"
strip -x "$SCRIPT_DIR/bin/clamshell"
codesign --force --sign - "$SCRIPT_DIR/bin/clamshell"

cp "$BUILD_SCRATCH/arm64-apple-macosx/release/ClamshellApp" "$APP_BUNDLE/Contents/MacOS/ClamshellApp"
strip -x "$APP_BUNDLE/Contents/MacOS/ClamshellApp"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/ClamshellApp"

cp "$SCRIPT_DIR/bin/clamshell" "$APP_BUNDLE/Contents/Resources/clamshell"
chmod 755 "$APP_BUNDLE/Contents/MacOS/ClamshellApp" "$APP_BUNDLE/Contents/Resources/clamshell"

VERSION="$(grep 'public let ClamshellVersion =' Sources/ClamshellCore/UpdateChecker.swift | cut -d '"' -f2)"

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ClamshellApp</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.wixe.clamshell.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Clamshell</string>
    <key>CFBundleDisplayName</key>
    <string>Clamshell</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_BUNDLE"

ln -s /Applications "$STAGING_DIR/Applications"

echo "💿 Packaging Drag-and-Drop DMG ($DMG_PATH)..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Clamshell" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ -w "/Applications" ]]; then
    TRASH_OLD="/tmp/Clamshell-build-old-$RANDOM.app"
    mv /Applications/Clamshell.app "$TRASH_OLD" 2>/dev/null || true
    cp -R "$APP_BUNDLE" /Applications/Clamshell.app 2>/dev/null || true
    rm -rf "$TRASH_OLD" 2>/dev/null || true
fi

rm -rf "$BUILD_SCRATCH" "$STAGING_DIR"

echo "✅ Built $DMG_PATH and installed /Applications/Clamshell.app"
ls -lh "$DMG_PATH"
