#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# 注意：此脚本仅打包主应用，不含 helper。如需 helper（低电量模式），请使用 build-app.sh。

APP_NAME="BatteryBar"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_DIR="Sources/BatteryBar/Resources"

echo "Building $APP_NAME..."
swift build -c release

echo "Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$ICON_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$ICON_DIR/AppIcon.png" "$APP_BUNDLE/Contents/Resources/"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BatteryBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.batterybar.app</string>
    <key>CFBundleName</key>
    <string>电池监测</string>
    <key>CFBundleDisplayName</key>
    <string>电池监测</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Done: $APP_BUNDLE"
echo "Run with: open $APP_BUNDLE"
