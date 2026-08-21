#!/bin/bash
set -e

# 最低系统要求：macOS 14.0（Sonoma）
# Helper 安装方式：使用 osascript + sudo（不走 SMJobBless），故主应用与 helper 的
# Info.plist 不再包含 SMPrivilegedExecutables / SMAuthorizedClients。

APP_NAME="BatteryBar"
HELPER_NAME="BatteryBarHelper"
# 分发用 release 构建：debug 构建的 Swift 6 运行时在实测中空转约 40% CPU
# （2026-08-22 排查，详见 MAINTENANCE_PLAN T-29），release 构建空闲为 0
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="com.batterybar.app"
HELPER_BUNDLE_ID="com.batterybar.helper"

echo "=== 编译 $APP_NAME 和 $HELPER_NAME（release） ==="
swift build -c release

echo "=== 创建 App Bundle ==="
# 清理旧的 bundle
rm -rf "$APP_BUNDLE"

# 创建目录结构
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制主应用
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# === Helper 打包 ===
# Helper 暂存为 bundle（保留 Info.plist 和签名步骤），最终只把已签名的可执行文件
# 放入 app bundle 的 Resources，供 Bundle.main.path(forResource:) 查找。
# 运行时通过 osascript 安装到 /Library/PrivilegedHelperTools，不走 SMJobBless。
HELPER_STAGING="$BUILD_DIR/BatteryBarHelper.bundle"
rm -rf "$HELPER_STAGING"
mkdir -p "$HELPER_STAGING/Contents/MacOS"
cp "$BUILD_DIR/$HELPER_NAME" "$HELPER_STAGING/Contents/MacOS/"

echo "=== 创建 Info.plist ==="

# 主应用 Info.plist（无 SMPrivilegedExecutables，使用 osascript 安装 helper）
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
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

# Helper Info.plist（无 SMAuthorizedClients，使用 osascript 安装，不走 SMJobBless）
cat > "$HELPER_STAGING/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$HELPER_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$HELPER_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$HELPER_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

echo "=== 代码签名 ==="
# 签名 helper bundle
codesign --force --sign - --entitlements /dev/stdin "$HELPER_STAGING" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# 复制已签名 helper 可执行文件到 app bundle 的 Resources
cp "$HELPER_STAGING/Contents/MacOS/$HELPER_NAME" "$APP_BUNDLE/Contents/Resources/"

# 签名主应用
codesign --force --sign - --entitlements /dev/stdin "$APP_BUNDLE" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

echo "=== 完成 ==="
echo "App Bundle: $APP_BUNDLE"
echo "Helper: $APP_BUNDLE/Contents/Resources/$HELPER_NAME"
echo ""
echo "运行: open $APP_BUNDLE"
