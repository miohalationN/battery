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
| 显示内容 | ✅ 已实现 | **纯文字百分比**（`XX%`），NSStatusBarButton attributedTitle 精确控宽，紧贴系统电池图标 |
| 深色/浅色跟随 | ✅ 已实现 | attributedTitle 使用动态 `.labelColor` |
| 低电量变红 | ✅ 已实现 | ≤20% 且未充电时文字变 `.systemRed`，插电后恢复 |
| 点击行为 | ✅ 已实现 | 左键展开 Popover 面板 |
| 右键菜单 | ✅ 已实现 | 打开主窗口 / 开机自启动（勾选） / 电池设置 / 关于 / 退出 |
| 开机自启动 | ✅ 已实现 | SMAppService Login Item，右键菜单开关；应用需安装在 /Applications 或 ~/Applications |
| 状态栏电池图标自绘 | 🚫 决策放弃 | 状态栏保持纯文字百分比，不复刻系统私有图标；应用本身使用独立 App 图标 |
| 应用图标 | ✅ 已实现 | 1024px PNG + 多尺寸 ICNS，构建脚本自动写入 App Bundle |
| Option+点击打开主窗口 | 📋 待办 | — |

### 2.2 Popover 面板（点击状态栏展开）

**布局：** 340×536pt，`.regularMaterial` 毛玻璃背景，卡片分组（圆角 12pt 半透明卡片，不用分隔线）

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

**窗口规格：** 默认 940×660pt（最小 840×580），可调整。主窗口由 `WindowGroup(id: "main")` 管理，采用固定侧栏 + 内容画布；打开时显示 Dock 图标，关闭后回到纯菜单栏模式。入口：右键菜单、Popover「查看详情」。

#### Tab 1：首页（电池概览）✅（2026-08-23 信息架构重构）

按「现在怎么样 → 为什么 → 详细信息」组织：

- 英雄卡：电量/充放电状态 + 可信的续航或充满估算 + 实时读数行
  （电池充入/放出功率 + 系统负载，系统负载标注来源：系统遥测 / 电池侧估算 / 当前不可用）
- 健康指标 4 格：健康度 / Apple 循环次数 / 温度 / 满充容量
- 当前时段趋势卡：离电/充电时段的电量曲线与时段摘要合并为一个区域
- 使用时间统计：亮屏 / 屏幕关闭·休眠 / 总计（显示器关闭但机器醒着计入"屏幕关闭/休眠"）
- 制造商、序列号、芯片名、电压、电流、协议等收进默认折叠的「电池与电源详情」

失效边界：页面根视图只读低频字段；每秒变化的瓦数拆进独立小视图；
时段曲线由快照通知/时段切换驱动的分析模型渲染，Chart 为输入 Equatable 的隔离子树。

#### Tab 2：电池健康 🚫 决策合并

- 原设计为独立 HealthTab（仪表盘/温度曲线/信息表）
- 2026-07-16 决策：删除独立 Tab，健康信息合并到首页指标卡与 Popover

#### Tab 2（现）：离电记录 ✅（2026-08-23 重命名 + 趋势归一化）

- 用户可见名称从「循环」改为「离电记录」；Apple 的 CycleCount 仍叫「循环次数」（概览页）。
  内部类型 ChargeCycle 保留，避免无意义迁移。
- 记录列表（惰性构造）：日期、起止电量、时长、放电百分比、平均电池功率
- 归一化趋势：折算满电续航 = 时长 ÷ 下降幅度 × 100（不同电量降幅可比）
- 只有下降 ≥5% 且持续 ≥15 分钟的记录参与归一化；样本不足明确显示「数据不足」

#### Tab 3：组件功耗 ✅（2026-08-23 功率口径修正）

- 主值为「系统负载」，标注数据来源（系统遥测 / 电池侧估算 / 当前不可用）；
  电池充入/放出功率作为独立次级指标，不再混叫总功耗
- 负载构成：CPU/GPU 为 powermetrics 实测；显示器明确标「估算」；
  占比只在系统负载有效且分项样本新鲜（<30s）时显示，否则仅显示绝对瓦数
- 历史趋势：系统负载曲线（240 保峰点）；统计只使用系统负载可用的快照
- 电压/电流/温度/适配器输入功率等诊断收进默认折叠的「电源诊断」
- Helper 开关与权限说明放到底部「高级采样」区域

### 功率口径（2026-08-23 定义）

| 概念 | 字段 | 说明 |
|------|------|------|
| 系统负载 | `systemLoadWatts` | 优先 PowerTelemetryData.SystemLoad（实测 mW→W）；离电时可用电池放出功率近似（标估算）；接电无遥测时不可用，禁止用充电功率冒充 |
| 电池功率 | `batteryPowerWatts` | abs(电压×电流)，充入/放出方向由 charging/source 表达 |
| 可用性标记 | `systemPowerAvailable` / `systemPowerIsEstimated` | 快照与实时信息都携带；旧快照按 v1 规则推导 |
| 适配器输入 | 实时诊断字段 | 不强制写历史 |

读取优先级：PowerTelemetryData.SystemLoad → BatteryData.SystemPower（可验证的旧节点）→
离电电池放电功率（estimated）→ 接电时不可用。
异常值过滤：nil、负值、非有限值、UInt64 回绕哨兵、超出合理设备范围的值。

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
| UI | SwiftUI + AppKit | 状态栏用 NSStatusItem + NSStatusBarButton；主窗口用 WindowGroup + 自定义侧栏。macOS 26+ 仅导航/主要操作采用原生 Liquid Glass，数据内容层使用动态实体表面以降低合成开销 |
| 并发模型 | PowerSampler / AppDelegate 隔离在 @MainActor | 2026-08-22 重构：阻塞调用（system_profiler / XPC helper）经 Task.detached 出主线程，结果回主线程 |
| 图表 | Swift Charts | 24h 功耗序列按时间桶保留局部极值，最多 240 点；Chart 隔离为 Equatable 子树，实时数字更新不重建历史 marks |
| 持久化 | JSON 文件（DataStore，串行队列保护） | 原设计 SwiftData，实现期替换 |
| 电池数据 | IOKit（IOPS + AppleSmartBattery registry） | **已适配 macOS 27**：容量字段改读 `BatteryData` 嵌套字典 |
| 分项功耗 | XPC Helper + `powermetrics`（root，可选） | 原设计 IOReport（私有框架不稳定）。4.1 延续懒启动流式进程（首个请求启动，60s 空闲自停），直接拒绝未授权 XPC；App 端缓存版本校验并禁止采样任务重叠 |
| 健康度 | `system_profiler`（60s 缓存） | — |
| 温度 | IORegistry `Temperature` 键 | Apple Silicon 部分系统不暴露，UI 显示「—」 |
| 电源事件 | NSWorkspace 通知（SleepWatcher） | — |
| 通知 | UserNotifications | — |
| WebDAV | 自建 URLSession + XMLParser | 无第三方依赖 |
| 凭据 | Keychain（AfterFirstUnlock） | — |
| 构建 | SPM + shell 脚本 + **GitHub Actions 云编译（release）** | 视图用 @State（宏插件随 Xcode 分发），推 main 分支云端编译；分发必须 release 构建（debug 运行时空转 ~38% CPU，T-29） |
| 签名 | ad-hoc | 原设计 Developer ID + 公证（发布时再做） |
| App Sandbox | **未开启** | Helper 安装需 osascript 提权，沙盒下不可行 |

### 数据模型

```
BatterySnapshot   id/timestamp/level/isCharging/wattage(=系统负载)/batteryPower/
                  systemPowerAvailable/systemPowerIsEstimated
                  /temperature/screenOn/cpuPower/gpuPower/displayPower/dramPower/dirty
ChargeCycle       id/startDate/endDate/startLevel/endLevel/totalEnergy/averageWattage/dirty
                  （语义：一次离电使用时段，非 Apple 循环次数）
SyncConfig        isEnabled/serverURL/username/remotePath/syncInterval/syncDirection/lastSyncAt/deviceID
BatteryInfo       静态信息（designCapacity/maxCapacity/cycleCount/serial/manufacturer/电压/电流/温度/适配器）
```

持久化位置：`~/Library/Application Support/BatteryBar/`
- `snapshots.jsonl`：追加式快照日志（每分钟一行，不重写）；过期行累计 ≥60 条（约 1 小时量）或 mark synced / 远端合并时才低频原子 compact；末尾损坏行跳过不致命（2026-08-23 起）
- `snapshots.json`：v1 全量数组，仅作迁移源与回退副本保留，不再写入
- `cycles.json` / `sync-config.json` / `usage-state.json` / `refresh-interval.json`
- 首次启动从 snapshots.json 无损迁移；保留窗口按 timestamp 裁剪 24h + 硬上限 1500 条

---

## 四、非功能需求

| 指标 | 要求 | 现状 |
|------|------|------|
| CPU 占用 | < 1% | ✅ 2026-08-22 实测 0.1%（修复 debug 构建空转 + NSTextField 状态栏布局风暴后；此前的 ~40% 从未被发现，因无测量手段） |
| 自身功耗 | < 0.5W | ✅ 随 CPU 修复（0.1% CPU ≈ 数十 mW） |
| 存储 | 24h ≈ 1440 条 < 1MB | ✅ 追加式 `snapshots.jsonl`（每分钟一行）；24h 按 timestamp 裁剪 + 1500 硬上限；解码失败自动备份 .bak |
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
| 中 | Helper 调用方校验升级：Developer ID 后改为硬编码 designated requirement（当前 ad-hoc 只能校验 bundle id） |
| 低 | Developer ID 签名 + 公证（发布前） |
| 低 | 状态栏事件驱动（IOPSNotification 替代 1s 轮询，降低自身功耗） |
