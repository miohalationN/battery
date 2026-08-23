# 电池监测

macOS 菜单栏电池与功耗监测应用。内部可执行文件、数据目录与 GitHub Artifact
暂时保留 `BatteryBar` 名称，以保证现有安装、历史数据、Helper 和自动化脚本无损兼容。

## 功能

- 状态栏纯百分比（紧贴系统电池图标，低电量变红）
- 左键 Popover 详情 / 右键菜单（主窗口、开机自启、电池设置、关于、退出）
- 开机自启动（右键菜单开关）
- 实时功耗显示（CPU/GPU 模型估算分项需开启 Helper；默认不运行特权采样）
- 电池健康度监控（已适配 macOS 27 字段变化）
- 低电量 / 充满通知
- 充放电循环统计与续航预估
- WebDAV 云同步（多设备数据合并）
- 原生侧栏式主窗口、交互曲线与独立 App 图标

## 安装

1. 下载 BatteryBar.dmg（或从 GitHub Actions 下载构建产物）
2. 拖动到 Applications（云编译产物建议装 `~/Applications`）
3. 默认零权限运行；如需 CPU/GPU 分项功耗，在「组件功耗」Tab 手动开启 Helper（安装时弹一次管理员密码）

## 开发

编译需要 Xcode（@State 宏插件仅随 Xcode 分发，CLT 编译不过），无本机 Xcode 时走云端：

```bash
# 本地（装有 Xcode 时）
swift test
bash update.sh

# 语法级预检查（无需 Xcode）
xcrun swiftc -parse Sources/**/*.swift
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

## 技术栈

- Swift 6.2
- SwiftUI + AppKit
- IOKit (电池数据)
- UserNotifications
- WebDAV (同步)
