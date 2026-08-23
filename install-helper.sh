#!/bin/bash
set -euo pipefail

# 开发者手动安装入口。生产 UI 使用 BatteryReader 内的同等安全流程；这里不再安装
# debug/未签名二进制，也不生成 RunAtLoad/KeepAlive 常驻 daemon。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/.build/release/BatteryBar.app"
HELPER_SOURCE="$APP_BUNDLE/Contents/Resources/BatteryBarHelper"
HELPER_ID="com.batterybar.helper"
INSTALL_PATH="/Library/PrivilegedHelperTools/$HELPER_ID"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_ID.plist"

cd "$SCRIPT_DIR"
bash build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"
codesign --verify --strict "$HELPER_SOURCE"

CLIENT_CDHASH="$(codesign -dvvv "$APP_BUNDLE/Contents/MacOS/BatteryBar" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
if [[ ! "$CLIENT_CDHASH" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    echo "无法取得已签名主程序 CDHash，拒绝安装" >&2
    exit 2
fi

echo "将安装按需启动的 BatteryBar Helper；需要管理员授权。"
sudo launchctl bootout "system/$HELPER_ID" 2>/dev/null || true
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$HELPER_SOURCE" "$INSTALL_PATH"
sudo tee "$PLIST_PATH" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_ID</string>
    <key>ProgramArguments</key>
    <array><string>$INSTALL_PATH</string></array>
    <key>MachServices</key>
    <dict><key>$HELPER_ID</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BATTERYBAR_AUTHORIZED_CLIENT_CDHASH</key>
        <string>$CLIENT_CDHASH</string>
    </dict>
</dict>
</plist>
PLIST
sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"
sudo launchctl bootstrap system/ "$PLIST_PATH"
echo "安装完成：Helper 将由 XPC 请求按需启动，并在空闲后退出。"
