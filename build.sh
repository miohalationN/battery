#!/bin/bash
set -euo pipefail

# 唯一发行打包入口，避免旧脚本遗漏 helper、签名或版本字段。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/build-app.sh"
