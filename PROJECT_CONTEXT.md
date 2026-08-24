# BatteryArchive（BA）— 项目上下文

> 维护工程师入门文档。读完此文档即可理解整体架构、数据流与约束。
> 更新日期：2026-08-24。仓库、可执行文件、Bundle ID 与数据目录仍保留内部兼容名 BatteryBar。

---

## 一、项目定位

**BatteryArchive（简称 BA，中文名“电池档案”）** 是一款 macOS 菜单栏常驻电池监控应用：记录离电时段、功耗趋势、电池健康、温度与有来源标记的实时遥测。

- 形态：菜单栏常驻 + 可选主窗口
- 最低系统：macOS 14（Package.swift 声明）
- 构建：纯 SPM，无 Xcode 工程；**编译依赖 Xcode——走 GitHub Actions 云编译**（`.github/workflows/build.yml`，推 main 分支自动构建，产物用 `gh run download` 下载装 `~/Applications`）。本地 CLT 缺 SwiftUIMacros/SwiftTesting 宏插件（后者可手动 `-load-plugin-library` 补上），可做语法检查与非视图层整体 typecheck；PowerSampler 自 2026-08-23 起为 @Observable（仅依赖 Observation 宏，CLT 可编译），SwiftUI 视图仍含 @State 等 Xcode 专属宏
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
    │   ├── App/                         # @main、集中品牌常量、自定义关于面板
    │   ├── Calc/
    │   │   ├── RuntimeEstimator.swift   # 多证据、置信度门控的续航/充电估算
    │   │   ├── ChartDownsampler.swift  # 功耗曲线时间桶保峰降采样
    │   │   └── OffPowerRecordAnalyzer.swift # 离电记录过滤与归一化趋势（纯函数）
    │   ├── Data/
    │   │   ├── BatteryReader.swift     # IOKit 读取（含系统遥测功率）+ XPC helper 客户端
    │   │   ├── PowerSampler.swift      # @Observable：事件/兜底采样、质量模型与 UI 状态中枢
    │   │   ├── SamplingCadence.swift   # 固定 5/15/60/10 秒节奏与事件合并纯策略
    │   │   ├── HelperLifecycle.swift   # 高级采样 Helper 生命周期与迟到结果门控
    │   │   ├── NotificationPolicy.swift # 通知触发门槛与冷却纯策略
    │   │   ├── CycleTracker.swift      # 离电使用时段检测
    │   │   ├── DataStore.swift         # JSON/JSONL 持久化（快照为追加日志）
    │   │   ├── NotificationManager.swift # UNUserNotificationCenter 封装
    │   │   └── SleepWatcher.swift      # NSWorkspace 系统/屏幕休眠与唤醒监听
    │   ├── MenuBar/
    │   │   └── PopoverView.swift       # Popover 面板内容（卡片化设计，宽 340）
    │   ├── Models/
    │   │   ├── BatteryInfo.swift       # 电池实时+静态信息 struct
    │   │   ├── BatterySnapshot.swift   # Codable 快照（当前 v5，v1–v4 兼容）
    │   │   ├── ChargeCycle.swift       # Codable 离电时段记录
    │   │   ├── SyncConfig.swift        # 同步配置 + 枚举
    │   │   └── TimeRange.swift         # 时间范围枚举
    │   ├── Sync/
    │   │   ├── WebDAVClient.swift      # WebDAV HTTP 客户端 + XML 解析
    │   │   ├── SyncEngine.swift        # 同步调度
    │   │   └── KeychainHelper.swift    # Keychain 读写
    │   ├── Views/
    │       ├── DesignSystem.swift      # 设计令牌、页面标题、卡片、图表图例与空态
    │       ├── UsageTab.swift          # 电池概览（英雄卡/健康指标/时段趋势/使用时间/折叠详情）
    │       ├── CycleTab.swift          # 离电记录（归一化趋势 + 惰性列表）
    │       ├── PowerTab.swift          # 功耗分析（系统负载口径 + 折叠诊断 + 高级采样）
    │       ├── PowerChartPlot.swift    # 系统负载历史曲线（Equatable 隔离）
    │       └── SyncTab.swift           # 同步设置
    │   └── Resources/
    │       ├── AppIcon.png             # BA 字标运行时/Dock 1024px 图标
    │       └── AppIcon.icns            # BA 字标 Finder/App Bundle 多尺寸图标
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
| 健康度 | `system_profiler SPPowerDataType -json` | 小时级 TTL，后台读取；容量比仅回退 |
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
  │    ├─ NSStatusItem + NSStatusBarButton（纯文字百分比）
  │    │    ├─ attributedTitle + 固定 statusItem.length（NSAttributedString 测宽 + ceil + 2pt）
  │    │    ├─ ≤20% 且未充电时前景色变 .systemRed；labelColor 动态跟随深浅模式
  │    │    ├─ sendAction(on: [.leftMouseUp, .rightMouseUp])：左键 togglePopover，右键 NSMenu
  │    │    │    （打开主窗口[经 OpenWindowRelay 通知] / 开机自启动勾选 / 电池设置 / 关于 / 退出）
  │    │    └─ 右键菜单临时挂 statusItem.menu，performClick 显示后置 nil 恢复左键行为
  │    ├─ NSPopover → PopoverMenuBarView（内含 openWindow 环境与 findExistingMainWindow）
  │    ├─ 开机自启动：SMAppService.mainApp register/unregister（右键菜单开关）
  │    └─ syncEngine.start(config:)（若 isEnabled && syncInterval != .manual）
  └─ WindowGroup("main") → ContentView → 固定侧栏导航（4 个功能区）
       ├─ environment(appDelegate.sampler/loginItem) + environmentObject(syncEngine)
       ├─ onAppear/onDisappear 切换 Dock 图标显示（.regular/.accessory）
       └─ background(OpenWindowRelay())：右键菜单「打开主窗口」通知 → openWindow(id:"main")
```

AppDelegate 为 @MainActor，持有唯一的 PowerSampler 和 SyncEngine 实例，主窗口通过 `appDelegate.sampler` / `appDelegate.syncEngine` 共享。`start()` 内部 `guard !isStarted` 保证幂等。SyncTab 通过 `@ObservedObject syncEngine` 实时显示同步状态（idle/syncing/success/failed）。

### 4.2 事件驱动 + 固定兜底采样（`PowerSampler`，@MainActor + @Observable）

```
start()
 ├─ readBatteryReading()/sampleStorage()          // 启动立即读取并写一个历史点
 ├─ 任一读数界面可见：基础兜底每 5s；均不可见：每 15s（固定、不可调）
 ├─ 主窗口/Popover 每次打开立即读取；两个界面分别登记，最后一个关闭才降频
 ├─ IOPS 电源变化、低电量模式、热压力通知立即读取；约 180ms 合并通知风暴
 ├─ Timer(target: fireStorage) 每 60s → sampleStorage()
 ├─ 高级采样开启时独立每 10s 读取 Helper 缓存；默认关闭
 ├─ SleepWatcher.start()（系统 willSleep/didWake + screensDidSleep/screensDidWake 四路通知；
 │   回调经 MainActor.assumeIsolated 同步直达，避免 willSleep → 入睡间 Task 排队延迟丢失统计）
 ├─ Task.detached 后台 readSystemHealth()（system_profiler 1-3s，不能上主线程）
 ├─ reader.prefetchStaticInfo() → 后台加载机型/序列号；无需广播，
 │   下次采样经 shouldPublishMetadata 比对后写入 currentInfo（属性级失效）
 └─ Helper 只做休眠态磁盘版本检查；不自动安装、不建立 XPC、不请求管理员授权

sampleUI()/applyBaseReading():
 ├─ reader.readBatteryReading()      // 同一轮 IOPS + IORegistry，失败则保留旧状态并形成缺口
 ├─ 按值变化门控写 @Observable 属性：Observation 属性级追踪——视图 body 读到哪个属性
 │   就只在它变化时失效；页面根视图不读瓦数等高频字段，历史 Chart 不被采样 tick 带着重建
 ├─ TelemetrySample 更新 availability/source/isEstimated/readAt/changedAt/stableFor
 ├─ WindowTelemetryAggregator 按真实覆盖时长累计 Wh、温度、亮屏/低电量模式/热状态份额
 ├─ 电量/充电态变化时按 NotificationPolicy 评估提醒，权限未知或电源来源未知不投递
 ├─ 插拔检测（拔电立即重置统计，30 秒内重插拔平滑过渡）
 └─ 电源切换或最多每 30s 用有界输入重算 RuntimeEstimator；证据不足显示“正在校准”

sampleStorage():
 ├─ 构造 BatterySnapshot v5（wattage=系统负载、batteryPower=电池功率、screenOn=亮屏且未休眠）
 │   → DataStore.saveSnapshot → 追加一行 jsonl，落盘后发 batterySnapshotsDidChange
 ├─ 离电时按 isSleeping || screensSleeping 计入「屏幕关闭/休眠」，否则计入亮屏
 ├─ CycleTracker.update(isPluggedIn, level, batteryPower)（只按明确插拔分段）
 └─ 每 5 分钟持久化 UsageState
```

### 4.3 离电时段检测（`CycleTracker`）

- 状态机只接受明确 `isPluggedIn`，禁止用 `!isCharging` 推断离电。
- `接电 → 离电` 开始记录；`离电 → 接电` 结束。满电保持、优化充电暂停和 80% 上限
  都是接电态，不产生伪离电记录。
- `OffPowerRecordAnalyzer` 仅让下降 ≥5% 且持续 ≥15 分钟的记录参与归一化趋势；
  列表仍可显示其他有效记录，证据不足明确显示“数据不足”。

### 4.3.1 续航/充电估算（`RuntimeEstimator`）

- 离电证据：历史电量 Theil–Sen 鲁棒斜率、最近 15 分钟可信电池放电 Wh、系统剩余时间；
  系统值独立展示，不与 App 证据静默混算。
- 充电估算只接受正斜率且净增长 ≥1%；暂停、涓流或坏容量/电压输入拒绝。
- 两路 App 证据按置信度融合；相差 >2 倍时降置信并扩大区间；最终置信度 <0.40 返回 nil。
- 输入有界：最多 120 个快照 + 120 个分钟点；只在新分钟、电源切换或最多 30 秒重算。

### 4.4 持久化（`DataStore`）

- 路径：`~/Library/Application Support/BatteryBar/`
  - `snapshots.jsonl`：**追加式快照日志**（2026-08-23 起）。每条采样只追加一行；
    mark synced / 远端合并 / 超窗裁剪时才整体原子 compact。首次启动从
    `snapshots.json`（v1 全量数组）无损迁移，旧文件保留作回退副本，不删除。
  - 保留窗口：按 **timestamp** 裁剪 24 小时（`retainedSnapshots`，容忍 ±5min 时钟偏差，
    拒绝 >5min 的未来点），另有 1500 条硬上限防御脏数据。
  - 末尾半行/单行损坏只跳过该行，不影响其余历史加载。
  - `cycles.json` / `sync-config.json` / `usage-state.json`；旧 `refresh-interval.json`
    仅兼容保留，运行时不再读取也不删除
- 串行 `DispatchQueue(label: "com.batterybar.store", qos: .utility)`
- 对外访问全部通过 `queue.sync` 包装的访问器：`allSnapshots()` / `recentSnapshots(_:)` / `allCycles()` / `currentConfig()` / `updateConfig(_:)`
- **解码失败兜底**：load() 中 snapshots/cycles/config 解码失败时先把原文件移为 `*.bak`（覆盖旧备份）再从空数据重建，os.Logger 记录；写盘失败同样记日志，不再静默吞错
- **可测试性**：`DataStore(directory:)` 可注入目录（单测用临时目录隔离），`flushPendingWritesForTesting()` 等待队列排空；配套 `DataStoreJournalTests`

### 4.5 Privileged Helper（可选，默认关闭，当前版本 5.0）

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
- 安装：`osascript ... with administrator privileges` 拷贝 + bootstrap；「高级采样」开关关闭
  **绝不卸载**（只停止分项采样并清空读数）；只有「采样诊断 → 移除辅助服务…」显式二次确认
  后才调用 `uninstallHelper()`（bootout + 删除二进制与 plist，弹一次管理员密码框）
- 版本升级：启动只做磁盘 CDHash 休眠态检查；发现缺失/旧版时关闭运行态并提示，只有用户再次主动开启才安装或更新（会弹密码框）。5.0 还把安装时主程序 CDHash 写入 launchd 环境，Helper 同时校验 bundle id 与该 CDHash
- **流式模式**：v3 的「每次调用 spawn powermetrics + 5s 超时保护 + replyOnce」已移除，XPC 调用直接回缓存，无阻塞无超时问题；mW/uW/W 三单位解析保留
- **采样器版本兼容**：macOS 27 起移除 `dram` 采样器（`--samplers` 带无效名会整体失败，分项功耗全 0——这是 v3 在 macOS 27 上的隐性回归，4.0 修复）；helper 按 `ProcessInfo.operatingSystemVersion` 门控，<27 才附带 dram，DRAM 功耗在 27 上为 0（UI 已按 0 隐藏）
- **启动失败退避**：powermetrics 存活 <10s 视为启动失败，连续 3 次进入 60s 冷却，防止重启风暴
- **调用方校验**：`processIdentifier` → `SecCodeCopyGuestWithAttributes` → `SecCodeCheckValidity`（代码未被篡改）+ bundle id；5.0 再与安装时绑定的客户端 CDHash 比对，失败直接拒绝连接。局限：ad-hoc 签名无 TeamID；正式 Developer ID 后仍宜改为硬编码 designated requirement
- **App 热路径**：高级采样独立每 10s 读取一次缓存且禁止并发重叠；关闭、stop 或生命周期非 enabled 时不发 XPC，迟到结果由 `ComponentReadingGate` 丢弃
- **Helper 并发模型**：`@unchecked Sendable` + 队列收敛（所有可变状态只在 powerQueue 串行队列访问）；`getComponentPower` 的 reply 闭包在协议中标注 `@Sendable`
- **主程序端超时**：`readComponentPower` 3s semaphore，`needsHelperUpdate` 2s semaphore（保留，兼容异常场景）
- **HelperProtocol 双定义**：主程序端 `@objc optional`（兼容旧 helper），Helper 端必选。未抽取 shared target 是有意设计

### 4.6 WebDAV 同步（`SyncEngine` + `WebDAVClient`）

```
SyncEngine.sync(config:)
 ├─ tryStartSyncing()（NSLock + isSyncing，封装在同步函数中避免 async NSLock）
 ├─ ensureDirs (MKCOL)
 ├─ upload:
 │    ├─ dirtySnapshots 按 day 分组 → jsonl.gz → PUT（含 batteryWatt/powerAvailable/
 │    │   powerEstimated 新字段；`BatterySnapshot.from(remoteJSON:)` 对远端旧格式按
 │    │   v1 规则推导口径：充电→仅电池功率，离电→估算系统负载）
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

### 4.7 通知（`NotificationManager` + `NotificationPolicy` 纯策略）

- 低电量提醒门槛（纯策略 `NotificationPolicy.shouldSendLowBattery`）：外接电源必须明确
  == false（true/nil 禁止）、当前未充电、开关开启、权限有效、电量 ≤20%、30 分钟冷却
- 充满提醒门槛（`shouldSendFullCharge`）：外接电源 == true、前一状态明确充电、当前停止
  充电、电量 ≥100%、开关开启、权限有效、60 分钟冷却
- 冷却时间戳持久化到 UserDefaults（`BatteryBarLastLowBatteryNotifAt` /
  `BatteryBarLastFullChargeNotifAt`），BA 重启后仍遵守冷却窗口
- 启动/创建管理器/读取电量都不请求权限；只有用户在设置页主动开启某个提醒开关且授权
  为 notDetermined 时才请求；denied 时开关恢复真实关闭并给出系统设置入口
- 首次初始化按授权状态推导：authorized/provisional 视为旧用户两开关默认开启、
  notDetermined/denied 默认关闭；写入版本化 initialized 标记后不覆盖用户选择

---

## 五、数据流

```
┌─────────────────────────────────────────────────────────────┐
│ IOKit (AppleSmartBattery / IOPS)                            │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ BatteryReader   │  (无状态读取 + XPC 客户端；系统负载/电池功率双口径)
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐    事件 + 5/15s UI 兜底 / 每 60s 存储
              │ PowerSampler    │  (@Observable, @MainActor, 事件 + 5/15s 兜底、60s 落盘)
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
6. **续航/充电估算**：只用 `RuntimeEstimator` 的历史 Theil–Sen 斜率、15 分钟电池放电功率与系统剩余时间三类独立证据；输入各有 120 条硬上限，总置信度 <0.40 必须返回 nil，不得恢复固定机型功耗表、默认 11.1V 或“证据不足仍给数字”的路径；禁止在 View body 扫描 DataStore
7. **本地优先**：所有数据先写本地，同步是可选功能
8. **状态栏只显示纯百分比**：`XX%` 格式，跟随系统逻辑，充电时不显示预估时间；≤20% 且未充电时 attributedTitle 变红（`.systemRed`，`.labelColor` 为动态色自动跟随深浅模式）。宽度控制：`button.attributedTitle` + 固定 `statusItem.length`（`NSAttributedString.size()` 测宽 + `ceil` + 2pt 余量）。**禁止把 NSTextField 嵌入 NSStatusBarButton**——macOS 27 实测会触发 AppKit 布局引擎持续重排，空转约 37% CPU（T-30，2026-08-22 用 20 行最小复现定位）
9. **状态栏深色/浅色模式自动跟随**：`attributedTitle` 使用动态 `.labelColor`（低电量时 `.systemRed`），无需手动监听外观切换
10. **SyncEngine 并发保护**：`tryStartSyncing()` / `endSyncing()` 同步函数封装 NSLock（async 函数中不能直接调用 NSLock.lock/unlock）
11. **修改前先读代码**；本机只有 CLT 时先运行 `xcrun swiftc -parse`，完整 `swift build` / `swift test` 与 UI 实机验收必须在带 Xcode 的环境或 CI 完成
12. **macOS 27 IOKit 字段兼容**：顶层 `DesignCapacity` 已移除、`MaxCapacity` 语义变为百分比，容量类字段必须优先读 `BatteryData` 嵌套字典（`DesignCapacity`/`FullChargeCapacity`），保留旧系统回退；`Temperature` 键可能不存在，UI 必须容忍 0 值（显示「—」，不得当作 0°C 参与算法）
13. **Popover 卡片化设计**：分区用紧凑圆角卡片与淡彩边缘，禁用 Divider；充电/已插电未充电/放电三种状态统一结构且均带电量进度条；电压/电流只能作为次要小字展示
14. **并发隔离**：`PowerSampler` 与 `AppDelegate` 均为 `@MainActor`，可观察状态一律 `private(set)`；阻塞调用（system_profiler / XPC helper）必须经 `Task.detached` 出主线程；休眠回调用 `MainActor.assumeIsolated`（SleepWatcher 通知在主线程派发）
15. **主窗口走 SwiftUI WindowGroup**：由 `WindowGroup(id: "main")` 保留系统窗口材质与生命周期；ContentView 使用自定义侧栏导航，不恢复系统 TabView 顶栏
16. **CycleTracker / RuntimeEstimator / OffPowerRecordAnalyzer / WindowTelemetryAggregator 可测试性**：时间、输入与落盘边界均可注入，配套反例在 `Tests/BatteryBarTests/`；修改算法必须同步更新测试
17. **SwiftUI 失效边界（2026-08-23 起）**：`PowerSampler` 为 `@Observable`（Observation 属性级追踪，替代旧 objectWillChange 全树广播）。页面根视图只读低频字段并持有历史状态；高频瓦数/组件读数拆进独立小视图；历史分析模型只在快照通知或范围切换时重算；禁止在 View body 里做全量排序、多个 filter/map/reduce、寻找时段或生成分析模型。Chart 一律包成输入 Equatable 的隔离子树（`.equatable()`）。滚动内容用 LazyVStack
18. **可观察属性必须值变才写**：每个采样 tick 无条件写会让读取该属性的视图反复重算（objectWillChange 时代曾烧约 40% CPU）；`sampleUI` 对 level/isCharging/wattage(0.05W 阈值)/温度/电压/电流/BatteryInfo(需 Equatable) 全部门控
19. **分发必须 release 构建**：Swift 6 debug 构建的运行时在本机实测空转约 38% CPU（release 同代码为 0，T-29）；`build-app.sh`/`build.sh`/`build-dmg.sh`/`update.sh`/CI 均已 `-c release`
20. **状态栏刷新门控保留**：refreshTitle 文字/低电量态未变时跳过 title/length 赋值；宽度用 `button.attributedTitle` + `NSAttributedString.size()` 测宽 + 固定 length（禁止 NSTextField 子视图，见 T-30）
21. **功率双口径与电源语义（2026-08-23 第二轮修正）**：`wattage` 一律指**系统负载**；电池包功率单独用 `batteryPower` 表达。`isCharging` 只表示电池包正在充入——满电保持、优化充电暂停、80% 上限都是 externalConnected=true 且 isCharging=false，**禁止把 !isCharging 当作离电**。快照 v3 起持久化 `externalConnected`（键缺失=来源未知，不得推断）。读取优先级：PowerTelemetryData.SystemLoad → BatteryData.SystemPower → 明确离电时的电池放电功率（估算）→ 接电无遥测时不可用。`trustedSystemLoad`：实测遥测始终保留；估算负载仅 externalConnected==false 时可信——来源未知的估算点（含已迁移的历史污染点）保守排除出系统负载统计、续航估算与离电时段。CycleTracker/UsageSessionModel 分段只认插拔状态
22. **屏幕状态统计**：`screenOn` 表示屏幕亮着（`!isSleeping && !areScreensSleeping`），监听 NSWorkspace screensDidSleep/screensDidWake；显示器关闭但机器醒着的分钟计入「屏幕关闭/休眠」，不得计入亮屏。UI 文案无法严格区分显示器关闭与系统睡眠时统一写「屏幕关闭/休眠」
23. **快照存储为追加日志**：每分钟只追加一行 `snapshots.jsonl`，禁止恢复每分钟全量重写；过期行（被 24h 窗口挤出）在内存立即收敛、文件侧延迟清理，累计 ≥60 条（约 1 小时量，稳态实测每分钟一条会恰好触发边界）才做一次原子 compact；mark synced / 远端合并即时 compact；迁移必须保留旧 `snapshots.json` 作回退；dirty 同步语义不得为写优化让步
24. **离电记录 ≠ Apple 循环次数**：记录页展示的是本 app 检测的离电使用时段（内部类型 ChargeCycle）；趋势只用归一化指标（折算满电续航/每小时耗电百分比），且仅纳入下降 ≥5% 且持续 ≥15 分钟的记录，样本不足显示「数据不足」；Apple 的 CycleCount 一律叫「循环次数」。「上次充电摘要」需正电量变化 ≥1% 且时长 ≥5 分钟，否则显示暂无有效记录
25. **UI Profile 钩子（默认休眠）**：UserDefaults「BatteryBarProfileAutoScroll」「BatteryBarProfileSection」仅在 Instruments 采样时由脚本设置，驱动页面内连续滚动与初始页选择（本机无辅助功能权限无法外部注入事件、CLT 无 xctrace）；正常使用路径零影响，不新增常驻动画

---

## 七、维护工程师上手清单

1. 通读本文档与 `MAINTENANCE_PLAN.md`
2. 本机运行 `bash scripts/local-gate.sh`（CLT 无 SwiftUIMacros 时，直接 `swift test` 失败属于已知环境限制）
3. 功能冻结后只推送一次，等待 GitHub Build + UI Profile 绿，再安装该 Build 的 release artifact
4. 验证状态栏显示 `XX%`
5. 点击状态栏文字打开 popover，验证数据显示
6. 打开主窗口，切换 4 个 Tab 验证图表
7. PowerTab 开启 Helper 开关验证 CPU/GPU 功耗显示
