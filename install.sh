#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Clamshell Zero-Dependency Installer (macOS / Apple Silicon Native)
# https://github.com/wixe/clamshell
# ==============================================================================

echo "========================================================================"
echo "🦪 Installing Clamshell — Clamshell Backlight & Keep-Awake Governor"
echo "========================================================================"

if [[ $EUID -ne 0 ]]; then
   echo "❌ Error: This installer must be run as root."
   echo "   Please run: sudo ./install.sh"
   exit 1
fi

INSTALL_DIR="/usr/local/bin"
SUPPORT_DIR="/Library/Application Support/clamshell"
mkdir -p "$INSTALL_DIR" "$SUPPORT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
PREBUILT_PATH="$SCRIPT_DIR/bin/clamshell"
BIN_PATH=""

if [[ "${1:-}" == "--build" ]]; then
    echo "🔨 Compiling Clamshell from source..."
    cd "$SCRIPT_DIR"
    swift build -c release --build-system native || swift build -c release
    if [[ -f "$SCRIPT_DIR/.build/arm64-apple-macosx/release/clamshell" ]]; then
        BIN_PATH="$SCRIPT_DIR/.build/arm64-apple-macosx/release/clamshell"
    else
        BIN_PATH="$SCRIPT_DIR/.build/release/clamshell"
    fi
elif [[ -f "$PREBUILT_PATH" ]]; then
    echo "📦 Using precompiled Apple Silicon binary (bin/clamshell)..."
    BIN_PATH="$PREBUILT_PATH"
else
    echo "⬇️  Downloading precompiled Clamshell binary from GitHub..."
    TMP_BIN="$(mktemp /tmp/clamshell.XXXXXX)"
    curl -fsSL "https://raw.githubusercontent.com/wixe/clamshell/main/bin/clamshell" -o "$TMP_BIN"
    BIN_PATH="$TMP_BIN"
fi

echo "📦 Installing binary to $INSTALL_DIR/clamshell and $SUPPORT_DIR/clamshelld..."
rm -f "$INSTALL_DIR/clamshell" "$SUPPORT_DIR/clamshelld"
install -m 755 "$BIN_PATH" "$INSTALL_DIR/clamshell"
install -m 755 "$BIN_PATH" "$SUPPORT_DIR/clamshelld"
xattr -cr "$INSTALL_DIR/clamshell" "$SUPPORT_DIR/clamshelld" 2>/dev/null || true
codesign --force --sign - "$INSTALL_DIR/clamshell" 2>/dev/null || true
codesign --force --sign - "$SUPPORT_DIR/clamshelld" 2>/dev/null || true

if [[ "$BIN_PATH" == /tmp/clamshell.* ]]; then
    rm -f "$BIN_PATH"
fi

echo "⚙️  Configuring LaunchDaemon (io.github.wixe.clamshell.daemon)..."
launchctl bootout system/io.github.wixe.clamshell.daemon 2>/dev/null || true
rm -f /Library/LaunchDaemons/io.github.wixe.clamshell.daemon.plist 2>/dev/null || true

"$INSTALL_DIR/clamshell" install

echo "🖥  Installing Clamshell.app to /Applications..."
DMG_PATH="$SCRIPT_DIR/dist/Clamshell.dmg"
TMP_DMG=""
if [[ ! -f "$DMG_PATH" ]]; then
    TMP_DMG="$(mktemp /tmp/Clamshell.XXXXXX.dmg)"
    curl -fsSL "https://github.com/wixe/clamshell/raw/main/dist/Clamshell.dmg" -o "$TMP_DMG"
    DMG_PATH="$TMP_DMG"
fi

MOUNT_DIR="$(mktemp -d /tmp/clamshell-mnt.XXXXXX)"
if hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -quiet; then
    rm -rf "/Applications/Clamshell.app"
    cp -R "$MOUNT_DIR/Clamshell.app" "/Applications/Clamshell.app"
    hdiutil detach "$MOUNT_DIR" -quiet || true

    CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || echo "${SUDO_USER:-}")"
    if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
        chown -R "$CONSOLE_USER:admin" "/Applications/Clamshell.app" 2>/dev/null || true
    fi

    xattr -cr "/Applications/Clamshell.app" 2>/dev/null || true
    codesign --force --deep --sign - "/Applications/Clamshell.app" 2>/dev/null || true
fi
rmdir "$MOUNT_DIR" 2>/dev/null || true
if [[ -n "$TMP_DMG" ]]; then
    rm -f "$TMP_DMG"
fi

echo ""
echo "✅ Installation complete! (/Applications/Clamshell.app + Background Daemon clamshelld)"
echo ""
"$INSTALL_DIR/clamshell" status
