# BatteryBar — 项目上下文

> 维护工程师入门文档。读完此文档即可理解整体架构、数据流与约束。
> 更新日期：2026-07-17

---

## 一、项目定位

**BatteryBar** 是一款 macOS 菜单栏常驻电池监控应用，将 iPhone「设置 → 电池」的核心体验搬到 Mac：自上次充电以来的使用时长、耗电曲线、电池健康、实时功耗，一目了然。

- 形态：菜单栏常驻 + 可选主窗口
- 最低系统：macOS 14（Package.swift 声明）
- 构建：纯 SPM，无 Xcode 工程
- 分发：DMG / `update.sh` 直接装到 `/Applications`
- 权限：默认零权限运行；CPU/GPU 分项功耗需用户在 PowerTab 手动开启 Helper（安装时弹一次管理员密码）

---

## 二、文件结构

```
battery/
├── Package.swift                       # SPM 清单，2 个 target
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
    │   │   └── PopoverView.swift       # Popover 面板内容
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
| 电池数据 | IOKit (`IOPSCopyPowerSourcesInfo` + `AppleSmartBattery` registry) | 用户态，无权限 |
| 系统功耗 | `powermetrics` 子进程（Helper） | 仅在用户开启 Helper 时 |
| 健康度 | `system_profiler SPPowerDataType -json` | 60s 缓存 |
| 电源事件 | `NSWorkspace` 通知（`SleepWatcher`） | 补足睡眠时长 |
| 通知 | `UserNotifications` | 低电量/充满提醒 |
| 特权操作 | `NSXPCConnection` + `BatteryBarHelper` LaunchDaemon | 读取 CPU/GPU/DRAM 功耗 |
| WebDAV | 自建 `URLSession` + `XMLParser` | 无第三方依赖 |
| 凭据 | Keychain Services | — |
| 构建 | SPM + 自定义 shell 脚本 | 无 Xcode 工程 |
| 签名 | ad-hoc（`codesign --sign -`） | 通过 osascript 安装 helper |

---

## 四、核心业务流程

### 4.1 启动

```
BatteryBarApp (@main)
  ├─ AppDelegate（持有唯一的 PowerSampler + SyncEngine 实例）
  │    ├─ NSStatusItem + NSStatusBarButton + 子 NSTextField（纯文字百分比）
  │    │    ├─ statusItem.length = ceil(fittingSize.width) + 2（固定宽度，消除系统 padding）
  │    │    ├─ textField.textColor = .labelColor（自动跟随系统深色/浅色模式）
  │    │    ├─ textField 右对齐到 button 右边缘，余量在左侧（% 紧贴系统电池图标）
  │    │    └─ 点击 button → togglePopover
  │    ├─ NSPopover → PopoverMenuBarView
  │    └─ syncEngine.start(config:)（若 isEnabled && syncInterval != .manual）
  └─ WindowGroup("main") → ContentView → TabView(4 个 Tab)
       ├─ environmentObject(appDelegate.sampler)
       └─ environmentObject(appDelegate.syncEngine)
```

AppDelegate 持有唯一的 PowerSampler 和 SyncEngine 实例，主窗口通过 `appDelegate.sampler` / `appDelegate.syncEngine` 共享同一实例。`start()` 内部 `guard !isStarted` 保证幂等。SyncTab 通过 `@ObservedObject syncEngine` 实时显示同步状态（idle/syncing/success/failed）。

### 4.2 采样循环（`PowerSampler`）

```
start()
 ├─ sampleUI()          // 立即一次
 ├─ sampleStorage()     // 立即一次
 ├─ DispatchSourceTimer 每 uiInterval(=1s, 可持久化配置) → sampleUI()
 ├─ Timer 每 60s → fireStorage() → sampleStorage()
 ├─ SleepWatcher.start()
 ├─ 后台 readSystemHealthPercent()
 ├─ reader.prefetchStaticInfo() → 后台加载机型/序列号（避免每秒 spawn system_profiler）
 └─ 观察刷新间隔变更通知 + 静态信息加载完成通知

sampleUI():
 ├─ reader.readPowerSource()         // IOPS
 ├─ reader.readBatteryInfo()         // IORegistry（读缓存，不再每秒 spawn system_profiler）
 ├─ 更新 @Published 状态
 ├─ NotificationCenter.post("PowerSamplerDidUpdate") → AppDelegate 刷新 button.title
 ├─ NotificationManager.checkLowBattery(level, isCharging:)（充电时不触发低电量）
 ├─ 插拔检测（拔电立即重置统计，30 秒内重插拔平滑过渡）
 ├─ 每 10 个 tick readComponentPower（仅 helperEnabled 时，用独立计数器避免时间戳取模）
 └─ 每 30 个 tick 重算 cachedDrainRate / cachedChargeRate（DrainRateCalculator 共享实现，避免 View 每 tick 全量扫描 DataStore）

sampleStorage():
 ├─ 构造 BatterySnapshot → DataStore.saveSnapshot
 ├─ screenOnMinutes / sleepMinutes += 1
 ├─ CycleTracker.update(isCharging, level, wattage)
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
- 机型基准放电速率通过 `sysctl hw.model` 检测（MacBookAir/Pro，M1/M2/M3/M4/Intel 区分）
- 健康度因子：`100 / max(50, healthPercent)` 调整基准速率
- 拔电初期（前 120s）优先历史数据，无历史用机型基准
- PowerSampler 每 30 个 tick 缓存一次到 `@Published cachedDrainRate / cachedChargeRate`

### 4.4 持久化（`DataStore`）

- 路径：`~/Library/Application Support/BatteryBar/`
  - `snapshots.json`（超过 2000 条时裁剪到 1440）
  - `cycles.json`
  - `sync-config.json`
  - `usage-state.json`（screenOnMinutes、sleepMinutes、lastPlugInTime 等）
- 串行 `DispatchQueue(label: "com.batterybar.store", qos: .utility)`
- 对外访问全部通过 `queue.sync` 包装的访问器：`allSnapshots()` / `recentSnapshots(_:)` / `allCycles()` / `currentConfig()` / `updateConfig(_:)`

### 4.5 Privileged Helper（可选，默认关闭）

```
App 端                                  Helper（root LaunchDaemon）
readComponentPower()  ──XPC──→  getComponentPower → powermetrics → 解析 CPU/GPU/DRAM
                                   ↑ 5s 超时保护 + replyOnce 防重复回调
                                   ↑ 支持 mW / uW / W 三种单位解析
```

- **默认关闭**：用户在 PowerTab 手动开启 Toggle 后才安装
- 安装：`osascript ... with administrator privileges` 拷贝 + bootstrap
- 安装成功后才写 `UserDefaults.BatteryBarHelperEnabled = true`（避免密码取消时开关仍显示开启）
- Helper 路径：`/Library/PrivilegedHelperTools/com.batterybar.helper`
- LaunchDaemon plist：`/Library/LaunchDaemons/com.batterybar.helper.plist`
- 未开启时：Popover 和 PowerTab 隐藏 CPU/GPU/内存功耗行，只显示总功率
- **powermetrics 单位兼容**：支持 mW（最常见）/ uW / W 三种输出格式，正则 `(?<![mu])W` 确保不误匹配 mW/uW 中的 W
- **Helper 超时保护**：`DispatchQueue.global().asyncAfter(5s)` 超时 `terminate` 进程；`replyOnce` 防止超时后正常完成导致重复回调
- **主程序端超时**：`readComponentPower` 3s semaphore，`needsHelperUpdate` 2s semaphore
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
6. **drain rate 计算**：由 `DrainRateCalculator` 统一实现（历史 0.6 + 功率 0.4 权重），PowerSampler 每 30 个 tick 缓存到 `@Published cachedDrainRate`；禁止在 View body 里全量扫描 DataStore
7. **本地优先**：所有数据先写本地，同步是可选功能
8. **状态栏只显示纯百分比**：`XX%` 格式，跟随系统逻辑，充电时不显示预估时间。用 `NSTextField.sizeToFit() + fittingSize` 测量文字精确宽度（`NSString.size` 会因小数丢损失裁切 `%`），`ceil + 2pt` 余量设为 `statusItem.length`（固定值，非 variableLength），消除 NSStatusBarButton 系统默认 padding；textField 右对齐到 button 右边缘，余量在左侧（`%` 紧贴系统电池图标）
9. **状态栏深色/浅色模式自动跟随**：`textField.textColor = .labelColor`，系统外观切换时自动更新，无需手动监听
10. **SyncEngine 并发保护**：`tryStartSyncing()` / `endSyncing()` 同步函数封装 NSLock（async 函数中不能直接调用 NSLock.lock/unlock）
11. **修改前先读代码**，修改后运行 `swift build` 验证

---

## 七、维护工程师上手清单

1. 通读本文档与 `MAINTENANCE_PLAN.md`
2. `swift build` 确认能编译
3. `bash build-app.sh && open .build/debug/BatteryBar.app` 跑起来
4. 验证状态栏显示 `XX%`
5. 点击状态栏文字打开 popover，验证数据显示
6. 打开主窗口，切换 4 个 Tab 验证图表
7. PowerTab 开启 Helper 开关验证 CPU/GPU 功耗显示
