# BatteryBar — 项目上下文

> 维护工程师入门文档。读完此文档即可理解整体架构、数据流与约束。
> 更新日期：2026-08-22

---

## 一、项目定位

**BatteryBar** 是一款 macOS 菜单栏常驻电池监控应用，将 iPhone「设置 → 电池」的核心体验搬到 Mac：自上次充电以来的使用时长、耗电曲线、电池健康、实时功耗，一目了然。

- 形态：菜单栏常驻 + 可选主窗口
- 最低系统：macOS 14（Package.swift 声明）
- 构建：纯 SPM，无 Xcode 工程；**本地 Command Line Tools 即可完整构建与测试**（2026-08-22 起视图状态迁移到 @Observable 模型，不再使用 @State 宏——其宏插件仅随 Xcode 分发）。GitHub Actions 云编译保留作分发用途（`.github/workflows/build.yml`，推 main 分支自动构建，产物用 `gh run download` 下载）
- 分发：DMG / `update.sh` 直接装到 `/Applications`（云编译产物建议装 `~/Applications`，旧 root 版本无法覆盖）
- 权限：默认零权限运行；CPU/GPU 分项功耗需用户在 PowerTab 手动开启 Helper（安装时弹一次管理员密码）
- 开机自启动：`SMAppService.mainApp`（macOS 13+ Login Item），状态栏右键菜单开关；要求 app 为正规 bundle 且位于 /Applications 或 ~/Applications，直接跑 .build 裸二进制注册会失败（开关弹提示说明）

---

## 二、文件结构

```
battery/
├── Package.swift                       # SPM 清单，2 个 target
├── .github/workflows/build.yml         # GitHub Actions 云编译（本机无 Xcode）
├── README.md                           # 简要说明
├── REQUIREMENTS.md                     # 产品需求文档（设计稿，可能与实现有差异）
├── PROJECT_CONTEXT.md                  # 本文件
├── MAINTENANCE_PLAN.md                 # 维护计划与变更日志
├── build.sh                            # 仅构建主 app bundle（无 helper）
├── build-app.sh                        # 构建 app + helper bundle 并签名
├── build-dmg.sh                        # 构建 DMG（无 helper）
├── install-helper.sh                   # sudo 手动安装 helper 到系统目录
├── update.sh                           # 重新构建并装到 /Applications
└── Sources/
    ├── BatteryBar/
    │   ├── App/BatteryBarApp.swift     # @main 入口；AppDelegate（状态栏 + syncEngine）；ContentView（主窗口 TabView）
    │   ├── Calc/
    │   │   └── DrainRateCalculator.swift # 放电/充电速率共享计算器（sysctl 机型检测）
    │   ├── Data/
    │   │   ├── BatteryReader.swift     # IOKit 读取 + XPC helper 客户端
    │   │   ├── PowerSampler.swift      # ObservableObject：定时采样、UI 状态中枢（含 drainRate 缓存）
    │   │   ├── CycleTracker.swift      # 充放电循环检测
    │   │   ├── DataStore.swift         # JSON 文件持久化
    │   │   ├── NotificationManager.swift # UNUserNotificationCenter 封装
    │   │   └── SleepWatcher.swift      # NSWorkspace 休眠/唤醒监听
    │   ├── MenuBar/
    │   │   └── PopoverView.swift       # Popover 面板内容（卡片化设计，宽 340）
    │   ├── Models/
    │   │   ├── BatteryInfo.swift       # 静态电池信息 struct
    │   │   ├── BatterySnapshot.swift   # Codable 快照
    │   │   ├── ChargeCycle.swift       # Codable 循环
    │   │   ├── SyncConfig.swift        # 同步配置 + 枚举
    │   │   └── TimeRange.swift         # 时间范围枚举
    │   ├── Sync/
    │   │   ├── WebDAVClient.swift      # WebDAV HTTP 客户端 + XML 解析
    │   │   ├── SyncEngine.swift        # 同步调度
    │   │   └── KeychainHelper.swift    # Keychain 读写
    │   └── Views/
    │       ├── UsageTab.swift          # 首页 Tab（电量曲线、使用时间）
    │       ├── CycleTab.swift          # 循环统计 Tab
    │       ├── PowerTab.swift          # 组件功耗 Tab
    │       └── SyncTab.swift           # 同步设置 Tab
    └── BatteryBarHelper/
        └── main.swift                  # XPC privileged helper（root，读取 powermetrics）
```

---

## 三、技术栈

| 层 | 选型 | 备注 |
|----|------|------|
| 语言 | Swift | 严格并发模式 |
| UI | SwiftUI + AppKit | 状态栏用 NSStatusItem + NSStatusBarButton + 子 NSTextField（精确控制宽度） |
| 图表 | Swift Charts | 系统框架 |
| 持久化 | JSON 文件（`DataStore`） | 串行 DispatchQueue 保护 |
| 电池数据 | IOKit (`IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry) | 用户态，无权限；**已适配 macOS 27**（容量字段在 `BatteryData` 嵌套字典） |
| 系统功耗 | `powermetrics` 子进程（Helper） | 仅在用户开启 Helper 时 |
| 健康度 | `system_profiler SPPowerDataType -json` | 60s 缓存 |
| 电源事件 | `NSWorkspace` 通知（`SleepWatcher`） | 补足睡眠时长 |
| 通知 | `UserNotifications` | 低电量/充满提醒 |
| 特权操作 | `NSXPCConnection` + `BatteryBarHelper` LaunchDaemon | 读取 CPU/GPU/DRAM 功耗 |
| WebDAV | 自建 `URLSession` + `XMLParser` | 无第三方依赖 |
| 凭据 | Keychain Services | — |
| 构建 | SPM + 自定义 shell 脚本 + GitHub Actions 云编译 | 无 Xcode 工程；本机仅 CLT 无法编译 SwiftUI 宏 |
| 签名 | ad-hoc（`codesign --sign -`） | 通过 osascript 安装 helper |

---

## 四、核心业务流程

### 4.1 启动

```
BatteryBarApp (@main)
  ├─ AppDelegate（@MainActor；持有唯一的 PowerSampler + SyncEngine 实例）
  │    ├─ NSStatusItem + NSStatusBarButton + 子 NSTextField（纯文字百分比）
  │    │    ├─ statusItem.length = ceil(fittingSize.width) + 2（固定宽度，消除系统 padding）
  │    │    ├─ textField.textColor = .labelColor（自动跟随系统深色/浅色模式）
  │    │    ├─ ≤20% 且未充电时文字变 .systemRed（低电量变红）
  │    │    ├─ sendAction(on: [.leftMouseUp, .rightMouseUp])：左键 togglePopover，右键 NSMenu
  │    │    │    （打开主窗口 / 开机自启动勾选 / 电池设置 / 关于 / 退出）
  │    │    └─ 右键菜单临时挂到 statusItem.menu，performClick 显示后置 nil 恢复左键行为
  │    ├─ NSPopover → PopoverMenuBarView(sampler:onOpenDetails:)
  │    ├─ showMainWindow()：NSWindow + NSHostingController(ContentView)，frameAutosaveName 记忆位置，
  │    │    isReleasedWhenClosed = false（关窗不销毁，可反复打开）；
  │    │    开窗 setActivationPolicy(.regular)，windowWillClose 后回 .accessory
  │    ├─ 开机自启动：SMAppService.mainApp register/unregister（右键菜单开关）
  │    └─ syncEngine.start(config:)（若 isEnabled && syncInterval != .manual）
  └─ Scene 仅 Settings { EmptyView() }（占位；主窗口不走 WindowGroup，
     启动不开窗，避免自动开窗与激活策略切换的时序问题）
```

AppDelegate 为 @MainActor，持有唯一的 PowerSampler 和 SyncEngine 实例，主窗口通过 `environmentObject` 注入共享。`start()` 内部 `guard !isStarted` 保证幂等。SyncTab 通过 `@ObservedObject syncEngine` 实时显示同步状态（idle/syncing/success/failed）。

### 4.2 采样循环（`PowerSampler`，@MainActor）

```
start()
 ├─ sampleUI()          // 立即一次
 ├─ sampleStorage()     // 立即一次
 ├─ DispatchSourceTimer 每 uiInterval(=1s, 可持久化配置) → Task { @MainActor } → sampleUI()
 ├─ Timer(target: fireStorage) 每 60s → sampleStorage()
 ├─ SleepWatcher.start()（回调经 MainActor.assumeIsolated 同步直达，
 │   避免 willSleep → 入睡间 Task 排队延迟丢失睡眠统计）
 ├─ Task.detached 后台 readSystemHealthPercent()（system_profiler 1-3s，不能上主线程）
 ├─ reader.prefetchStaticInfo() → 后台加载机型/序列号（避免每秒 spawn system_profiler）
 └─ 观察刷新间隔变更通知 + 静态信息加载完成通知（Task { @MainActor } 回主线程）

sampleUI():
 ├─ reader.readPowerSource()         // IOPS
 ├─ reader.readBatteryInfo()         // IORegistry（读缓存，不再每秒 spawn system_profiler）
 ├─ 更新 @Published 状态（全部 private(set)，仅主线程可写）
 ├─ NotificationCenter.post("PowerSamplerDidUpdate") → AppDelegate 刷新状态栏文字
 ├─ NotificationManager.checkLowBattery(level, isCharging:)（充电时不触发低电量）
 ├─ 插拔检测（拔电立即重置统计，30 秒内重插拔平滑过渡）
 ├─ 每 10 个 tick readComponentPower（仅 helperEnabled 时；XPC 阻塞调用经 Task.detached 出主线程）
 └─ 每 30 个 tick 重算 cachedDrainRate / cachedChargeRate
     （DrainRateCalculator 纯函数，快照数组由调用方传入，避免 View 每 tick 全量扫描 DataStore）

sampleStorage():
 ├─ 构造 BatterySnapshot → DataStore.saveSnapshot
 ├─ screenOnMinutes / sleepMinutes += 1
 ├─ CycleTracker.update(isCharging, level, wattage)（时钟与落盘 init 注入，可测试）
 └─ 每 5 分钟持久化 UsageState
```

### 4.3 循环检测（`CycleTracker`）

- 维护 `wasCharging` 前一状态
- `充电 → 放电`：新循环开始（放电阶段，记录 startLevel、startDate）
- `放电 → 充电`：循环结束（`duration > 300s` 才保存）
- `accumulatedDischarge` 累加 `max(0, cycleStartLevel - level)`
- `cycleWattageSamples` 记录放电期间功率采样，用于计算 `averageWattage`
- 相位已修正：cycle 表示放电阶段（拔电→插电），原实现错位导致 averageWattage 永远为 0

### 4.3.1 放电/充电速率计算（`DrainRateCalculator`）

- 统一算法（抽取自 UsageTab 和 PopoverView 的重复实现）：历史放电段速率 0.6 权重 + 当前功率 0.4 权重融合
- 纯函数：快照数组与 `now` 由参数注入，不读 DataStore / 系统时钟；配套单测 `DrainRateCalculatorTests`
- 机型基准：优先「机型典型功耗 ÷ 实测电池能量（满充容量 × 电压）」；容量未知才退回固定速率表 × 健康度因子
  （注意：不能用 hw.model 的 "m1"/"m2" 子串判断芯片代次——Apple Silicon 的 hw.model 是
  "Mac14,2" 平台键或 "MacBookAir10,1"，子串永远匹配不到，2026-08-22 修复）
- 拔电初期（前 120s）优先历史数据，无历史用机型基准
- PowerSampler 每 30 个 tick 取 recentSnapshots(1440) 调用一次，缓存到 `@Published cachedDrainRate / cachedChargeRate`

### 4.4 持久化（`DataStore`）

- 路径：`~/Library/Application Support/BatteryBar/`
  - `snapshots.json`（超过 2000 条时裁剪到 1440）
  - `cycles.json`
  - `sync-config.json`
  - `usage-state.json`（screenOnMinutes、sleepMinutes、lastPlugInTime 等）
- 串行 `DispatchQueue(label: "com.batterybar.store", qos: .utility)`
- 对外访问全部通过 `queue.sync` 包装的访问器：`allSnapshots()` / `recentSnapshots(_:)` / `allCycles()` / `currentConfig()` / `updateConfig(_:)`
- **解码失败兜底**：load() 中 snapshots/cycles/config 解码失败时先把原文件移为 `*.bak`（覆盖旧备份）再从空数据重建，os.Logger 记录；写盘失败同样记日志，不再静默吞错

### 4.5 Privileged Helper（可选，默认关闭，当前版本 4.0）

```
App 端                                  Helper（root LaunchDaemon，队列收敛在 powerQueue）
readComponentPower()  ──XPC──→  getComponentPower → 返回最近采样缓存（立即回包）
                                   ↑ 首个请求懒启动 powermetrics 流式进程（-i 10000，
                                     每 10s 一轮采样，readabilityHandler 逐行解析缓存）
                                   ↑ 60s 无 XPC 请求自动 terminate（app 关闭/关开关后零开销）
                                   ↑ 活跃期内意外退出 1s 后自动重启
shouldAcceptNewConnection → pid → SecCode 校验（签名有效 + bundle id == com.batterybar.app）
```

- **默认关闭**：用户在 PowerTab 手动开启 Toggle 后才安装
- 安装：`osascript ... with administrator privileges` 拷贝 + bootstrap；关闭开关时调用 `uninstallHelper()`（bootout + 删除二进制与 plist，弹一次管理员密码框）真正卸载
- 版本升级：`requiredHelperVersion` 不匹配时自动重装（会弹密码框）。4.0 = 流式 powermetrics + 调用方校验
- **流式模式**：v3 的「每次调用 spawn powermetrics + 5s 超时保护 + replyOnce」已移除，XPC 调用直接回缓存，无阻塞无超时问题；mW/uW/W 三单位解析保留
- **采样器版本兼容**：macOS 27 起移除 `dram` 采样器（`--samplers` 带无效名会整体失败，分项功耗全 0——这是 v3 在 macOS 27 上的隐性回归，4.0 修复）；helper 按 `ProcessInfo.operatingSystemVersion` 门控，<27 才附带 dram，DRAM 功耗在 27 上为 0（UI 已按 0 隐藏）
- **启动失败退避**：powermetrics 存活 <10s 视为启动失败，连续 3 次进入 60s 冷却，防止重启风暴
- **调用方校验**：`processIdentifier` → `SecCodeCopyGuestWithAttributes` → `SecCodeCheckValidity`（代码未被篡改）+ bundle id 匹配。局限：ad-hoc 签名无 TeamID，无法做同开发者强校验；Developer ID 后应改为硬编码 designated requirement
- **Helper 并发模型**：`@unchecked Sendable` + 队列收敛（所有可变状态只在 powerQueue 串行队列访问）；`getComponentPower` 的 reply 闭包在协议中标注 `@Sendable`
- **主程序端超时**：`readComponentPower` 3s semaphore，`needsHelperUpdate` 2s semaphore（保留，兼容异常场景）
- **HelperProtocol 双定义**：主程序端 `@objc optional`（兼容旧 helper），Helper 端必选。未抽取 shared target 是有意设计

### 4.6 WebDAV 同步（`SyncEngine` + `WebDAVClient`）

```
SyncEngine.sync(config:)
 ├─ tryStartSyncing()（NSLock + isSyncing，封装在同步函数中避免 async NSLock）
 ├─ ensureDirs (MKCOL)
 ├─ upload:
 │    ├─ dirtySnapshots 按 day 分组 → jsonl.gz → PUT（含 cpu/gpu/disp/dram 字段）
 │    └─ dirtyCycles → cycles.json → PUT（远程 dirty 默认 false，避免无限重传）
 └─ download:
      ├─ listFiles(snapshots/{deviceID}/) → 逐个 GET → 解压 → 解析 → mergeSnapshots
      └─ cycles.json → mergeCycles（远程 cycles dirty 重置为 false）
```

- 每设备一文件：`snapshots/{deviceID}/{day}.jsonl.gz`，避免覆盖他机数据
- 上传前先 GET 云端同设备同日文件 → 合并（timestamp 胜出）→ 压缩上传
- `SyncEngine.start(config:)` 在 AppDelegate 启动时若 `isEnabled && syncInterval != .manual` 自动启动
- 定时器回调中实时读取 `DataStore.shared.currentConfig()`，避免用旧配置
- `updateLastSyncAt(_:)` 只更新一个字段，避免覆盖用户在同步期间修改的其他配置（TOCTOU）
- `SyncState` 枚举（idle/syncing/success/failed）通过 `@Published` 暴露给 SyncTab
- 本地优先，`dirty` 标记；`ChargeCycle.init(from:)` 自定义解码让远程 dirty 默认 false
- Keychain 用 `kSecAttrAccessibleAfterFirstUnlock`，锁屏时仍可访问（适合后台同步）

### 4.7 通知（`NotificationManager`）

- 低电量 ≤20%，30 分钟冷却，**充电时不触发**（`checkLowBattery(level:isCharging:)`）
- 充满 ≥100% 且 `previousCharging && !currentIsCharging`，60 分钟冷却
- `lastLowBatteryNotification` / `lastFullChargeNotification` 用 NSLock 保护（completion handler 在后台队列）
- 启动即请求权限

---

## 五、数据流

```
┌─────────────────────────────────────────────────────────────┐
│ IOKit (AppleSmartBattery / IOPS)                            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ BatteryReader   │  (无状态读取 + XPC 客户端)
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐    每 1s UI / 每 60s 存储
              │ PowerSampler    │  (ObservableObject, @Published)
              └─────┬──────┬────┘
                    │      │
       ┌────────────┘      └─────────────┐
       ▼                                 ▼
 ┌──────────────┐                ┌──────────────┐
 │ SwiftUI 视图 │                │  DataStore   │ (JSON 文件)
 │ 状态栏 title │                └──────┬───────┘
 │ Popover      │                       │ dirty
 │ 4 个 Tab     │                       ▼
 └──────────────┘                ┌──────────────┐
                                 │ SyncEngine   │
                                 └──────┬───────┘
                                        ▼
                                 ┌──────────────┐
                                 │ WebDAVClient │ → 远程服务器
                                 └──────────────┘

旁路：
  PowerSampler ──→ NotificationManager ──→ UNUserNotificationCenter
  PowerSampler ──→ CycleTracker ──→ DataStore.cycles
  PowerSampler ──XPC──→ BatteryBarHelper (root) ──→ powermetrics（仅 helperEnabled 时）
```

---

## 六、关键约束（维护时必须遵守）

1. **纯 SPM 构建**，不引入 Xcode 工程
2. **无第三方依赖**（WebDAV 自建）
3. **IOKit 读取必须用户态**，不要求额外权限
4. **Helper 默认关闭**，用户手动开启时才安装；未开启时不显示 CPU/GPU/内存功耗
5. **电池使用时间统计**：拔电立即重置，30 秒内重插拔平滑过渡，仅离电时累加
6. **drain rate 计算**：由 `DrainRateCalculator` 统一实现（历史 0.6 + 功率 0.4 权重），纯函数——快照数组与时间由参数注入，不直接读 DataStore / 系统时钟；PowerSampler 每 30 个 tick 取 recentSnapshots(1440) 调用并缓存到 `@Published cachedDrainRate`；禁止在 View body 里全量扫描 DataStore
7. **本地优先**：所有数据先写本地，同步是可选功能
8. **状态栏只显示纯百分比**：`XX%` 格式，跟随系统逻辑，充电时不显示预估时间；≤20% 且未充电时 attributedTitle 变红（`.systemRed`，`.labelColor` 为动态色自动跟随深浅模式）。宽度控制：`button.attributedTitle` + 固定 `statusItem.length`（`NSAttributedString.size()` 测宽 + `ceil` + 2pt 余量）。**禁止把 NSTextField 嵌入 NSStatusBarButton**——macOS 27 实测会触发 AppKit 布局引擎持续重排，空转约 37% CPU（T-30，2026-08-22 用 20 行最小复现定位）；也禁止 `@main` SwiftUI App/Scene 脚手架（debug 构建下同样空转，见约束 18）
9. **状态栏深色/浅色模式自动跟随**：`textField.textColor = .labelColor`（低电量时 `.systemRed`，同为动态色），系统外观切换时自动更新，无需手动监听
10. **SyncEngine 并发保护**：`tryStartSyncing()` / `endSyncing()` 同步函数封装 NSLock（async 函数中不能直接调用 NSLock.lock/unlock）
11. **修改前先读代码**，修改后运行 `swift build` 验证；涉及算法/数据逻辑跑 `swift test`（本地 CLT 可完整构建与测试）。涉及 UI 的改动 `bash build-app.sh && open .build/debug/BatteryBar.app` 实机确认
12. **macOS 27 IOKit 字段兼容**：顶层 `DesignCapacity` 已移除、`MaxCapacity` 语义变为百分比，容量类字段必须优先读 `BatteryData` 嵌套字典（`DesignCapacity`/`FullChargeCapacity`），保留旧系统回退；`Temperature` 键可能不存在，UI 必须容忍 0 值（显示「—」，不得当作 0°C 参与算法）
13. **Popover 卡片化设计**：分区用圆角卡片（`.quaternary` 填充），禁用 Divider；充电/已插电未充电/放电三种状态统一结构且均带电量进度条；电压/电流只能作为次要小字展示
14. **并发隔离**：`PowerSampler` 与 `AppDelegate` 均为 `@MainActor`，`@Published` 一律 `private(set)`；阻塞调用（system_profiler / XPC helper）必须经 `Task.detached` 出主线程；休眠回调用 `MainActor.assumeIsolated`（SleepWatcher 通知在主线程派发）
15. **主窗口不走 SwiftUI WindowGroup**：AppDelegate `showMainWindow()` 以 NSWindow + NSHostingController 创建，`isReleasedWhenClosed = false`；新开窗入口（右键菜单 / Popover 查看详情）一律调 `showMainWindow()`，不要恢复 `@Environment(\.openWindow)`
16. **CycleTracker / DrainRateCalculator 可测试性**：时钟与落盘经 init/参数注入，配套单测在 `Tests/BatteryBarTests/`；修改算法必须同步更新测试
17. **视图状态用 @Observable 模型，禁止 @State**：@State 在新版 SDK 是宏（插件仅随 Xcode 分发，CLT 编译不过）。模式：每个 Tab 一个 `@Observable final class XxxModel`，由 AppDelegate 持有并注入（跨窗口关闭/重开保留状态）；视图里 `@Bindable var model` + 读侧计算属性透传（body 沿用原属性名）。**本地 `swift test` 可跑，CI 测试失败会阻断打包**（旧 `|| echo warning` 曾放过一个过期断言半个多月）
18. **@Published 必须值变才写**：每秒无条件写会让 objectWillChange 风暴式触发所有观察视图重算（曾在无窗口时烧约 40% CPU）；`sampleUI` 对 level/isCharging/wattage(0.05W 阈值)/温度/电压/电流/BatteryInfo(需 Equatable) 全部门控，`lastUpdateTime` 非 @Published，已删除每秒翻转的 `tick`（视图用 60s Timer 刷新快照）
19. **分发必须 release 构建**：Swift 6 debug 构建的运行时在本机实测空转约 38% CPU（release 同代码为 0，T-29）；`build-app.sh`/`build.sh`/`build-dmg.sh`/`update.sh`/CI 均已 `-c release`
20. **入口为纯 AppKit**：`@main enum BatteryBarApp` 直接 `NSApplication.shared.run()`，无 SwiftUI Scene；SwiftUI 仅用于 Popover 与主窗口内容（NSHostingController）

---

## 七、维护工程师上手清单

1. 通读本文档与 `MAINTENANCE_PLAN.md`
2. `swift build` 确认能编译
3. `bash build-app.sh && open .build/debug/BatteryBar.app` 跑起来
4. 验证状态栏显示 `XX%`
5. 点击状态栏文字打开 popover，验证数据显示
6. 打开主窗口，切换 4 个 Tab 验证图表
7. PowerTab 开启 Helper 开关验证 CPU/GPU 功耗显示
