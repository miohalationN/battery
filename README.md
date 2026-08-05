# BatteryBar

macOS 菜单栏电池监控应用

## 功能

- 状态栏纯百分比（紧贴系统电池图标）
- 实时功耗显示（CPU/GPU/内存分项需开启 Helper）
- 电池健康度监控（已适配 macOS 27 字段变化）
- 低电量 / 充满通知
- 充放电循环统计与续航预估
- WebDAV 云同步（多设备数据合并）

## 安装

1. 下载 BatteryBar.dmg（或从 GitHub Actions 下载构建产物）
2. 拖动到 Applications（云编译产物建议装 `~/Applications`）
3. 默认零权限运行；如需 CPU/GPU 分项功耗，在「组件功耗」Tab 手动开启 Helper（安装时弹一次管理员密码）

## 开发

本地需要完整 Xcode（仅 Command Line Tools 无法编译 SwiftUI 宏）。无 Xcode 环境时依赖 GitHub Actions 云编译：

```bash
# 本地编译（需要 Xcode）
swift build

# 运行
open .build/debug/BatteryBar.app

# 重新构建并安装到 /Applications
bash update.sh
```

### 云编译（无 Xcode 环境）

推送代码到 GitHub 后，Actions 会自动编译并打包 `BatteryBar.app`（约 4 分钟）：

1. 推送：`git push`
2. 等待 Build 完成：`gh run list` / `gh run view <id>`
3. 下载并安装：
   ```bash
   gh run download <run-id> -n BatteryBar
   ditto -x -k BatteryBar.zip ~/Applications/
   open ~/Applications/BatteryBar.app
   ```

本地语法预检查（无需 Xcode）：`xcrun swiftc -parse Sources/**/*.swift`

## 技术栈

- Swift 6.2
- SwiftUI + AppKit
- IOKit (电池数据)
- UserNotifications
- WebDAV (同步)
