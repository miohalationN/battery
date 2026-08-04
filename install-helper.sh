#!/bin/bash
set -e

HELPER_NAME="BatteryBarHelper"
HELPER_ID="com.batterybar.helper"
BUILD_DIR=".build/debug"
HELPER_BIN="$BUILD_DIR/$HELPER_NAME"
INSTALL_PATH="/Library/PrivilegedHelperTools/$HELPER_ID"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_ID.plist"

echo "=== 安装 BatteryBar Privileged Helper ==="
echo ""
echo "这需要管理员权限（只在首次安装时需要）"
echo ""

# 检查 helper 是否已编译
if [ ! -f "$HELPER_BIN" ]; then
    echo "编译 helper..."
    swift build --target BatteryBarHelper
fi

# 创建安装目录
echo "安装 helper 到系统目录..."
sudo mkdir -p /Library/PrivilegedHelperTools

# 复制 helper
sudo cp "$HELPER_BIN" "$INSTALL_PATH"
sudo chown root:wheel "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"

# 创建 launchd plist
echo "创建 launchd 配置..."
sudo tee "$PLIST_PATH" > /dev/null << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_PATH</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_ID</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"

# 加载 daemon
echo "加载 daemon..."
sudo launchctl bootout system/"$HELPER_ID" 2>/dev/null || true
sudo launchctl bootstrap system/"$PLIST_PATH"

echo ""
echo "=== 安装完成 ==="
echo ""
echo "Helper 已安装为系统服务，以 root 权限运行"
echo "之后切换低电量模式不需要再输入密码"
echo ""
echo "卸载命令："
echo "  sudo launchctl bootout system/$HELPER_ID"
echo "  sudo rm $INSTALL_PATH $PLIST_PATH"
