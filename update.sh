#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# 此脚本编译并更新 /Applications 中的 BatteryBar，helper 随 app 打包到 Resources。

APP_NAME="BatteryBar"
APP_PATH="/Applications/$APP_NAME.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

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
    <string>BatteryBar</string>
    <key>CFBundleDisplayName</key>
    <string>BatteryBar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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
echo "BatteryBar 已更新并启动"
echo ""
echo "首次切换低电量模式时会自动安装后台服务（需要输入密码）"
echo "之后切换不再需要密码"
