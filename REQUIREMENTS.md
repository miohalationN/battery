# BatteryBar — macOS 菜单栏电池监控应用

> 需求基线文档。本文档已与实际代码对齐（2026-08-22）。
> 有意偏离原始设计的决策均标注「决策」，尚未实现的项标注「待办」。

## 一、产品定位

一款 macOS 菜单栏常驻应用，将 iPhone 上「设置 → 电池」的核心体验搬到 Mac：自上次充电以来的使用时长、耗电曲线、电池健康、实时功耗，一目了然。

- 形态：菜单栏常驻（纯百分比文字）+ 可选主窗口
- 风格：系统材质 + 卡片分组，跟随系统亮/暗模式，不自定义主题

---

## 二、功能清单与实现状态

### 2.1 状态栏（Menu Bar）

| 项目 | 状态 | 说明 |
|------|------|------|
| 显示内容 | ✅ 已实现 | **纯文字百分比**（`XX%`），NSTextField 精确控宽，紧贴系统电池图标 |
| 深色/浅色跟随 | ✅ 已实现 | `textColor = .labelColor` 自动切换 |
| 低电量变红 | ✅ 已实现 | ≤20% 且未充电时文字变 `.systemRed`，插电后恢复 |
| 点击行为 | ✅ 已实现 | 左键展开 Popover 面板 |
| 右键菜单 | ✅ 已实现 | 打开主窗口 / 开机自启动（勾选） / 电池设置 / 关于 / 退出 |
| 开机自启动 | ✅ 已实现 | SMAppService Login Item，右键菜单开关；应用需安装在 /Applications 或 ~/Applications |
| 电池图标自绘 | 🚫 决策放弃 | 原需求要求像素级复刻系统图标，迭代 12 版无法达成，2026-07-16 决定改为纯文字 |
| Option+点击打开主窗口 | 📋 待办 | — |

### 2.2 Popover 面板（点击状态栏展开）

**布局：** 宽度 340pt，高度自适应，`.regularMaterial` 毛玻璃背景，卡片分组（圆角 12pt 半透明卡片，不用分隔线）

```
┌─────────────────────────────────────┐
│  🔋 78%  充电中                      │  ← 图标圈 + 大数字 + 状态
│  ┌ 状态卡片 ────────────────────┐   │
│  │ ⚡ 预计 1h 20m 后充满   28.6W │   │  三种状态统一结构：
│  │ ▓▓▓▓▓▓▓░░░ 电量进度条         │   │  充电中 / 已插电未充电 / 放电中
│  └─────────────────────────────┘   │  （放电时下方加 亮屏/休眠/当前功率 三列）
│  ┌ 实时功耗 ────────────────────┐   │
│  │ ⚡ 总功率          28.6 W     │   │
│  │ （Helper 开启时：CPU/GPU/内存/│   │
│  │   显示器分项）                │   │
│  │            12.5 V · 2290 mA  │   │  ← 电压/电流降级为次要小字
│  └─────────────────────────────┘   │
│  ┌ 电池健康 ────────────────────┐   │
│  │ 98%  [良好]                   │   │  ← 健康度大数字 + 状态标签
│  │ 循环次数 136 次               │   │
│  │ 满充容量 4240 / 4382 mAh      │   │
│  │ 温度     —（不可用时）        │   │
│  └─────────────────────────────┘   │
│  [ 查看详情（全宽按钮）]            │
│  电池设置                    退出   │
└─────────────────────────────────────┘
```

📋 待办：「自上次充电以来」使用合计行、预计总续航（已用 → 剩余 → 总计）

### 2.3 主窗口（详细视图）

**窗口规格：** 默认 760×580pt（最小 560×420），可调整，位置与大小记忆（frameAutosaveName），`.thickMaterial` 背景。主窗口由 AppDelegate 以 NSWindow + NSHostingController 管理（2026-08-22 决策）：启动保持纯菜单栏不开窗；打开主窗口时显示 Dock 图标，关闭后回到纯菜单栏模式。入口：右键菜单、Popover「查看详情」。

#### Tab 1：首页（使用记录）✅

- 状态卡（充电中/放电中 + 预计时间 + 功耗）
- 关键指标 4 格：循环 / 健康度 / 温度 / 容量
- 电量曲线（Swift Charts，充电/放电分段着色，悬停查看数值）
- 上次使用时长统计、电池信息区

#### Tab 2：电池健康 🚫 决策合并

- 原设计为独立 HealthTab（仪表盘/温度曲线/信息表）
- 2026-07-16 决策：删除独立 Tab，健康信息合并到首页指标卡与 Popover

#### Tab 2（现）：循环统计 ✅

- 循环列表（日期、时长、起止电量、平均功率；自动过滤电量下降 <1% 的无效循环）
- 续航能力趋势图
- 统计摘要（平均/最长循环续航）

#### Tab 3：组件功耗 ✅

- 系统总功耗 + 电压/电流/功率/温度卡片
- Helper 未开启时显示开启引导；开启后显示 CPU/GPU 分项（内存分项仅 macOS < 27——27 起系统移除 dram 采样器，UI 在数值为 0 时自动隐藏该行）
- 平均/峰值/最低功耗、功耗趋势图

#### Tab 4：同步 ✅（部分待办）

- WebDAV 服务器配置（地址/用户名/密码 Keychain 存储/远程路径）+ 测试连接 ✅
- 默认坚果云；支持任意 WebDAV ✅
- 同步间隔：15min / 1h / 6h / 手动 ✅
- 同步方向：双向 / 仅上传 / 仅下载 ✅
- 同步状态显示（idle/syncing/success/failed）✅
- 配置不完整（地址/用户名/密码为空）警告 ✅（2026-08-22）
- 📋 待办：同步日志（最近 50 条）、下次同步倒计时

### 2.4 通知 ✅

> 原始设计列为 YAGNI，后改为实现。

- 低电量 ≤20%：30 分钟冷却，充电时不触发
- 充满提醒：60 分钟冷却
- 启动即请求通知权限

---

## 三、技术架构（实际选型）

| 层 | 选型 | 与原设计差异 |
|----|------|-------------|
| 语言 | Swift 6.2（严格并发） | — |
| UI | SwiftUI + AppKit | 状态栏用 NSStatusItem + NSTextField（原设计 MenuBarExtra，为精确控宽弃用）；主窗口 NSWindow + NSHostingController（原 WindowGroup，为启动不开窗 + 任意入口拉起弃用） |
| 并发模型 | PowerSampler / AppDelegate 隔离在 @MainActor | 2026-08-22 重构：阻塞调用（system_profiler / XPC helper）经 Task.detached 出主线程，结果回主线程 |
| 图表 | Swift Charts | — |
| 持久化 | JSON 文件（DataStore，串行队列保护） | 原设计 SwiftData，实现期替换 |
| 电池数据 | IOKit（IOPS + AppleSmartBattery registry） | **已适配 macOS 27**：容量字段改读 `BatteryData` 嵌套字典 |
| 分项功耗 | XPC Helper + `powermetrics`（root，可选） | 原设计 IOReport（私有框架不稳定）。4.0 起 powermetrics 为懒启动常驻流式进程（首个请求启动，60s 空闲自停），XPC 校验调用方（签名有效 + bundle id 匹配）；关闭开关时真正卸载守护进程 |
| 健康度 | `system_profiler`（60s 缓存） | — |
| 温度 | IORegistry `Temperature` 键 | Apple Silicon 部分系统不暴露，UI 显示「—」 |
| 电源事件 | NSWorkspace 通知（SleepWatcher） | — |
| 通知 | UserNotifications | — |
| WebDAV | 自建 URLSession + XMLParser | 无第三方依赖 |
| 凭据 | Keychain（AfterFirstUnlock） | — |
| 构建 | SPM + shell 脚本 + **GitHub Actions 云编译** | 本机无 Xcode（CLT 缺 SwiftUI 宏插件），推 main 分支云端编译 |
| 签名 | ad-hoc | 原设计 Developer ID + 公证（发布时再做） |
| App Sandbox | **未开启** | Helper 安装需 osascript 提权，沙盒下不可行 |

### 数据模型

```
BatterySnapshot   id/timestamp/level/isCharging/wattage/temperature/screenOn
                  + cpuPower/gpuPower/displayPower/dramPower + dirty
ChargeCycle       id/startDate/endDate/startLevel/endLevel/totalEnergy/averageWattage/dirty
SyncConfig        isEnabled/serverURL/username/remotePath/syncInterval/syncDirection/lastSyncAt/deviceID
BatteryInfo       静态信息（designCapacity/maxCapacity/cycleCount/serial/manufacturer/电压/电流/温度/适配器）
```

持久化位置：`~/Library/Application Support/BatteryBar/`（snapshots.json / cycles.json / sync-config.json / usage-state.json / refresh-interval.json）

---

## 四、非功能需求

| 指标 | 要求 | 现状 |
|------|------|------|
| CPU 占用 | < 1% | ✅ 2026-08-22 实测 0.1%（修复 debug 构建空转 + NSTextField 状态栏布局风暴后；此前的 ~40% 从未被发现，因无测量手段） |
| 自身功耗 | < 0.5W | ✅ 随 CPU 修复（0.1% CPU ≈ 数十 mW） |
| 存储 | 24h ≈ 1440 条 < 1MB | ✅ 快照超 2000 条裁剪到 1440；⚠️ JSON 每 60s 全量重写（待优化）；解码失败自动备份 .bak |
| 冷启动 | < 1s | ✅ 耗时读取（system_profiler）全部后台化 |
| 隐私 | 不配置同步则零网络请求 | ✅ |

---

## 五、不做（YAGNI）

- ❌ 低电量模式切换（曾实现，2026-07-16 移除）
- ❌ 隐藏系统电池图标（曾实现，2026-07-16 移除）
- ❌ 多设备电量显示（iPhone/Apple Watch）
- ❌ 电池校准工具
- ❌ 自定义主题/皮肤
- ❌ Widget、菜单栏图表
- ✅ 通知功能（原列 YAGNI，后改为实现，见 2.4）

---

## 六、已知待办汇总

| 优先级 | 项目 |
|--------|------|
| 高 | Option+点击打开主窗口 |
| 中 | Popover 预计总续航区块；使用时长合计行 |
| 中 | 同步日志（最近 50 条）、下次同步倒计时 |
| 中 | JSON 增量写盘；多设备合并后的保留策略（本地 24h 裁剪与合并数据的冲突） |
| 中 | Helper 调用方校验升级：Developer ID 后改为硬编码 designated requirement（当前 ad-hoc 只能校验 bundle id） |
| 低 | Developer ID 签名 + 公证（发布前） |
| 低 | 状态栏事件驱动（IOPSNotification 替代 1s 轮询，降低自身功耗） |
