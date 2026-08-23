#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# 此脚本编译并更新 /Applications 中的 BatteryBar，helper 随 app 打包到 Resources。

APP_NAME="BatteryBar"
APP_PATH="/Applications/$APP_NAME.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_DIR="Sources/BatteryBar/Resources"

echo "=== 正在更新 $APP_NAME ==="

# 1. 关闭正在运行的 app
echo "关闭应用..."
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5

# 2. 编译（包含 helper）
echo "编译中..."
swift build -c release

# 3. 创建 app bundle
echo "打包中..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制主应用
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$ICON_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp "$ICON_DIR/AppIcon.png" "$APP_BUNDLE/Contents/Resources/"

# 复制 helper 到 Resources（app 内自动安装用）
cp "$BUILD_DIR/BatteryBarHelper" "$APP_BUNDLE/Contents/Resources/"

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

# 4. 替换 Applications 中的 app
echo "安装到 Applications..."
rm -rf "$APP_PATH"
cp -R "$APP_BUNDLE" "$APP_PATH"

# 5. 重新打开
echo "启动应用..."
open "$APP_PATH"

echo ""
echo "=== 更新完成 ==="
echo "电池监测已更新并启动"
echo ""
echo "首次开启高级分项采样时会安装后台服务（需要输入密码）"
