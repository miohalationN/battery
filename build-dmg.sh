#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# 始终复用 build-app.sh 的签名 App + Helper，避免 DMG 脚本产生未签名或残留旧 Helper
# 的第二套产物。

APP_NAME="BatteryBar"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_DIR="$BUILD_DIR/dmg"
VOLUME_NAME="电池档案"

echo "=== Building signed app bundle ==="
bash build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"

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
echo "2. Drag 电池档案 to Applications"
echo "3. Launch from Applications or Spotlight"
