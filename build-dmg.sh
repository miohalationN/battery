#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# 注意：此脚本仅打包主应用并生成 DMG，不含 helper。如需 helper（低电量模式），
# 请先运行 build-app.sh 生成完整 app bundle，再据此调整 DMG 打包。

APP_NAME="BatteryBar"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_DIR="$BUILD_DIR/dmg"
VOLUME_NAME="电池监测"
ICON_DIR="Sources/BatteryBar/Resources"

echo "=== Building $APP_NAME ==="
swift build -c release

echo "=== Creating app bundle ==="
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
    <string>4</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
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

echo "=== Creating DMG ==="
rm -rf "$DMG_DIR"
rm -f "$DMG_NAME"
mkdir -p "$DMG_DIR"

# 复制 app 到 DMG 目录
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# 创建 Applications 快捷方式
ln -s /Applications "$DMG_DIR/Applications"

# 创建 DMG
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

echo ""
echo "=== Done ==="
echo "DMG created: $DMG_NAME"
echo "Size: $(du -h "$DMG_NAME" | cut -f1)"
echo ""
echo "To install:"
echo "1. Open $DMG_NAME"
echo "2. Drag 电池监测 to Applications"
echo "3. Launch from Applications or Spotlight"
