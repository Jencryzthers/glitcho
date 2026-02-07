#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
APP_NAME="Glitcho"
APP_VERSION="1.2.0"
APP_BUILD="120"
APP_DIR="$BUILD_DIR/${APP_NAME}.app"

swift build -c release --package-path "$ROOT_DIR" --product "$APP_NAME"
swift build -c release --package-path "$ROOT_DIR" --product "GlitchoRecorderAgent"

BIN_PATH="$ROOT_DIR/.build/release/$APP_NAME"
AGENT_BIN_PATH="$ROOT_DIR/.build/release/GlitchoRecorderAgent"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Helpers"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "$AGENT_BIN_PATH" ]; then
    cp "$AGENT_BIN_PATH" "$APP_DIR/Contents/Helpers/GlitchoRecorderAgent"
    chmod +x "$APP_DIR/Contents/Helpers/GlitchoRecorderAgent" || true
fi
if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
touch "$APP_DIR" "$APP_DIR/Contents/Info.plist" "$APP_DIR/Contents/Resources" >/dev/null 2>&1 || true

cat <<PLIST > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.glitcho.app</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$APP_DIR" >/dev/null 2>&1 || true

echo "Built $APP_DIR"
