#!/bin/bash
set -euo pipefail

# 最低系统要求：macOS 14.0（Sonoma）
# 此脚本编译并更新 /Applications 中的 BatteryBar，helper 随 app 打包到 Resources。

APP_NAME="BatteryBar"
INSTALL_ROOT="${BATTERYBAR_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_ROOT/$APP_NAME.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "=== 正在更新 $APP_NAME ==="

# 1. 关闭正在运行的 app
echo "关闭应用..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

# 2–3. 统一使用正式打包脚本，避免 update.sh 产生未签名的第二种 App。
echo "编译并签名中..."
bash build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"

# 4. 替换 Applications 中的 app
echo "安装到 $INSTALL_ROOT..."
mkdir -p "$INSTALL_ROOT"
BACKUP_PATH="$INSTALL_ROOT/$APP_NAME.pre-update.$$.app"
if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$BACKUP_PATH"
fi
if ! ditto "$APP_BUNDLE" "$APP_PATH"; then
    if [ -e "$BACKUP_PATH" ]; then mv "$BACKUP_PATH" "$APP_PATH"; fi
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"
if [ -e "$BACKUP_PATH" ]; then rm -rf "$BACKUP_PATH"; fi

# 5. 重新打开
echo "启动应用..."
open "$APP_PATH"

echo ""
echo "=== 更新完成 ==="
echo "电池监测已更新并启动"
echo ""
echo "首次开启高级分项采样时会安装后台服务（需要输入密码）"
