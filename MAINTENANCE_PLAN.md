# BatteryBar — 维护计划

> 配合 `PROJECT_CONTEXT.md` 使用。本文件定义维护原则、验证策略与变更日志。
> 更新日期：2026-07-17

---

## 一、维护原则

1. **不破坏已有功能**：状态栏百分比、Popover、主窗口 4 个 Tab、同步、通知是核心功能，不能出现回归
2. **Bug 优先于性能，性能优先于重构**
3. **最小改动**：只改必要的代码，不顺手重构无关模块
4. **修改前必读代码**：理解上下文，禁止盲改
5. **修改后必验证**：至少 `swift build` 通过；涉及 UI 的改动需 `open .build/debug/BatteryBar.app` 跑一次

---

## 二、已知问题与待办

### 严重

| 编号 | 问题 | 文件 | 状态 |
|------|------|------|------|
| T-01 | `powermetrics` 每 10s 子进程，CPU 占用不可忽略（自身功耗可能 >0.5W） | BatteryReader.swift | 待办（设计如此，无法避免） |
| T-02 | `system_profiler` 极慢（1-3s），首次/过期后阻塞后台队列 | BatteryReader.swift | ✅ 已修复（后台 prefetchStaticInfo 缓存） |
| T-03 | JSON 全量重写：`saveJSON` 每 60s 把整个数组重新编码写盘 | DataStore.swift | 待办 |

### 中等

| 编号 | 问题 | 文件 | 状态 |
|------|------|------|------|
| T-04 | `BatteryReader.cachedHealthPercent` / `healthCacheTime` 是 `nonisolated(unsafe) static`，多线程读写无同步 | BatteryReader.swift | ✅ 已修复（NSLock 保护 + nonisolated(unsafe) 标注） |
| T-05 | `PowerSampler` / `CycleTracker` 标 `@unchecked Sendable`，模式脆弱 | PowerSampler.swift / CycleTracker.swift | 待办（需重构为 actor） |
| T-06 | `refreshInterval` 未生效：SyncTab 修改后 post 通知但 PowerSampler 未观察 | PowerSampler.swift | ✅ 已修复（观察通知 + 持久化到 refresh-interval.json） |
| T-07 | `HelperProtocol` 重复定义：BatteryReader.swift 与 BatteryBarHelper/main.swift 各一份 | BatteryReader.swift / main.swift | 保留（@objc optional 是有意兼容设计） |
| T-08 | 密码每次按键都写 Keychain：SyncTab SecureField.onChange 每字符调用 setPassword | SyncTab.swift | ✅ 已修复（0.6s 防抖 Task） |
| T-09 | SyncEngine 未暴露状态：UI 无法显示「正在同步/失败/成功」 | SyncEngine.swift / SyncTab.swift | ✅ 已修复（SyncState @Published + SyncTab 共享实例） |
| T-13 | WebDAV XMLParser 命名空间失效（`D:collection` 无法识别） | WebDAVClient.swift | ✅ 已修复（shouldProcessNamespaces + didStartElement） |
| T-14 | ChargeCycle dirty 无限重传（远程 dirty 解码后仍为 true） | ChargeCycle.swift / DataStore.swift | ✅ 已修复（自定义 init(from:) 默认 false + mergeCycles 重置） |
| T-15 | Keychain 锁屏不可读 | KeychainHelper.swift | ✅ 已修复（kSecAttrAccessibleAfterFirstUnlock） |
| T-16 | SyncEngine 并发同步（定时器 + 手动同步并发损坏数据） | SyncEngine.swift | ✅ 已修复（NSLock + tryStartSyncing/endSyncing 同步封装） |
| T-17 | SyncEngine TOCTOU（同步期间用户改配置被覆盖） | SyncEngine.swift | ✅ 已修复（updateLastSyncAt 只更新一个字段） |
| T-18 | NotificationManager 充电时误报低电量 | NotificationManager.swift | ✅ 已修复（checkLowBattery 增加 isCharging 参数） |
| T-19 | CycleTracker 相位错位（cycle 应为放电阶段） | CycleTracker.swift | ✅ 已修复（修正为放电周期） |
| T-20 | powermetrics 仅支持 mW 单位 | main.swift | ✅ 已修复（支持 mW/uW/W，正则 `(?<![mu])W`） |
| T-21 | Helper 无超时保护（waitUntilExit 阻塞卡死 RunLoop） | main.swift | ✅ 已修复（5s asyncAfter + terminate + replyOnce） |

### 轻微

| 编号 | 问题 | 文件 | 状态 |
|------|------|------|------|
| T-10 | 制造日期无法读取（Apple Silicon 硬件限制） | BatteryReader.swift | 待办（硬件限制） |
| T-11 | `drainRate`/`chargeRate` 在 UsageTab 与 PopoverView 重复实现 | UsageTab.swift / PopoverView.swift | ✅ 已修复（抽取 DrainRateCalculator） |
| T-12 | 机型基准目前仅适配 MacBook Air M1 | UsageTab.swift | ✅ 已修复（sysctl hw.model 检测多机型） |
| T-22 | onChange 旧语法 deprecation | SyncTab.swift | ✅ 已修复（迁移到零参数新语法） |
| T-23 | BatteryBarApp 双层 thickMaterial | BatteryBarApp.swift | ✅ 已修复（移除 WindowGroup 那层） |
| T-24 | PowerSampler previousLevel 未使用 | PowerSampler.swift | ✅ 已修复（删除） |

---

## 三、验证策略

### 编译验证（每次改动）

```bash
swift build
```

### 运行验证（涉及 UI / 行为）

```bash
bash build-app.sh && open .build/debug/BatteryBar.app
```

涉及以下场景必须人工 smoke test：
- 状态栏百分比显示（充电/非充电/满电）
- Popover 弹出、数据显示
- 主窗口 4 个 Tab 切换
- 通知（低电量、充满）
- 同步测试连接 + 立即同步
- PowerTab Helper 开关（安装/卸载）

### TSAN 验证（涉及并发改动）

```bash
swift build -c debug -Xswiftc -sanitize=thread
```

### 单元测试

```bash
swift test
```

---

## 四、回滚策略

- 每个独立修改独立提交，commit message 清晰
- 涉及数据格式改动（如 snapshots 文件结构）必须提供迁移逻辑
- 不直接删除老数据文件；新版读旧版失败时备份到 `*.bak` 后重建

---

## 五、变更日志

### 2026-08-04 — GitHub Actions 云编译链路 + macOS 27 数据修复 + Popover 卡片化重设计

> 背景：本机无 Xcode（仅 CLT 无法编译 SwiftUI 宏），建立云端编译链路；实机审查发现多个数据 bug 与 UI 问题。

#### 工程基础设施
- **GitHub Actions 云编译**：新增 `.github/workflows/build.yml`，推送 main 分支后云端 Xcode 编译 + `build-app.sh` 打包，产物 `BatteryBar.zip` 可下载（保留 30 天）
- **初始化 git 仓库**：首次提交全部源码与文档，`.gitignore` 排除构建产物与无关工具文件
- **清理**：删除逆向遗留 `conf.py`；README 修正（移除已删除的低电量模式描述，补充云编译流程）

#### 数据修复（macOS 27 兼容）
- **容量 0/0 mAh**：macOS 27 顶层 `DesignCapacity` 已移除、`MaxCapacity` 语义变为百分比，[BatteryReader.swift](Sources/BatteryBar/Data/BatteryReader.swift) 改读 `BatteryData.DesignCapacity` / `BatteryData.FullChargeCapacity`，兼容旧系统顶层 mAh 与 `FccComp1`
- **温度恒 0.0°C**：Apple Silicon 不暴露 `Temperature` 键，UI 显示「—」；修复 UsageTab 温控因素把 0°C 当极低温惩罚（系数 0.2）导致充满预估暴涨的连锁问题
- **充满预估跳变（7h→15h）**：[DrainRateCalculator.swift](Sources/BatteryBar/Calc/DrainRateCalculator.swift) `chargeRate()` 扩窗至 30 分钟 + 最小样本要求（≥3 快照/≥4 分钟/≥1% 变化）+ 3-80%/h 限幅；[PowerSampler.swift](Sources/BatteryBar/Data/PowerSampler.swift) 增加 EMA 平滑（0.6/0.4）
- **无效循环脏数据**：[CycleTracker.swift](Sources/BatteryBar/Data/CycleTracker.swift) 过滤电量下降 <1% 的循环（100%→100%）

#### Popover 重设计（[PopoverView.swift](Sources/BatteryBar/MenuBar/PopoverView.swift)）
- Divider 分隔改为卡片分组（圆角 + 半透明填充）
- 充电/已插电未充电/放电三种状态统一结构（均带电量进度条），新增「已插电，未充电」状态
- 电压/电流降级为次要小字，不再混在功耗列表
- 健康度突出显示 + 良好/一般/建议检修标签
- 功率为 0 时显示「—」

#### 验证
- CI 编译通过，产物安装后实机截图验证：容量 4240/4382 mAh、温度 —、充满预估稳定（约 0h 38m）、卡片布局正常

---

### 2026-07-17 — 全量代码审查 + 修复 24 个问题 + 深色模式支持确认

> 基于用户「挂多个 agent 完整检查整个程序的所有代码修复优化代码，优化性能占用逻辑 bug 等等内容」请求，执行 7 个批次的全量代码审查与修复。

#### 批次 1-3：同步路径与并发安全（已完成）
- **WebDAV XMLParser 命名空间失效**：[WebDAVClient.swift](Sources/BatteryBar/Sync/WebDAVClient.swift) 添加 `shouldProcessNamespaces = true`，`collection` 识别移到 `didStartElement`（自闭合空元素 `foundCharacters` 不触发）
- **组件功耗字段同步丢失**：[SyncEngine.swift](Sources/BatteryBar/Sync/SyncEngine.swift) 上传/下载路径补全 `cpuPower/gpuPower/displayPower/dramPower` 字段
- **ChargeCycle dirty 无限重传**：[ChargeCycle.swift](Sources/BatteryBar/Models/ChargeCycle.swift) 自定义 `init(from decoder:)` 让远程 dirty 默认 false；[DataStore.swift](Sources/BatteryBar/Data/DataStore.swift) `mergeCycles` 重置远程 dirty
- **Keychain 锁屏不可读**：[KeychainHelper.swift](Sources/BatteryBar/Sync/KeychainHelper.swift) `kSecAttrAccessibleWhenUnlocked` → `kSecAttrAccessibleAfterFirstUnlock`
- **SyncEngine 并发同步**：NSLock + isSyncing 标志，封装到 `tryStartSyncing()` / `endSyncing()` 同步函数（async 函数中不能直接调用 NSLock.lock/unlock）
- **SyncEngine TOCTOU**：新增 `updateLastSyncAt(_:)` 只更新一个字段，避免覆盖用户在同步期间修改的配置
- **SyncEngine 定时器用旧 config**：回调中实时读取 `DataStore.shared.currentConfig()`
- **NotificationManager 充电时误报低电量**：`checkLowBattery(level:isCharging:)` 新增 isCharging 参数
- **NotificationManager 时间戳数据竞争**：NSLock 保护 `lastLowBatteryNotification` / `lastFullChargeNotification`
- **CycleTracker 相位错位**：修正为放电周期（拔电→插电），原实现导致 `averageWattage` 永远为 0
- **system_profiler 主线程每秒阻塞**：[BatteryReader.swift](Sources/BatteryBar/Data/BatteryReader.swift) 新增 `prefetchStaticInfo()` 后台缓存机型/序列号，`readBatteryInfo()` 读缓存
- **nonisolated(unsafe) static 数据竞争**：`_cachedHealthPercent` / `_healthCacheTime` 用 NSLock 保护 + `nonisolated(unsafe)` 标注
- **powermetrics 触发条件脆弱**：[PowerSampler.swift](Sources/BatteryBar/Data/PowerSampler.swift) 用独立计数器替代 `Int(timeIntervalSince1970) % 10`
- **refreshInterval 不持久化**：[DataStore.swift](Sources/BatteryBar/Data/DataStore.swift) 新增 `refresh-interval.json` 持久化文件

#### 批次 4：DrainRateCalculator 共享计算器（已完成）
- **新建**：[DrainRateCalculator.swift](Sources/BatteryBar/Calc/DrainRateCalculator.swift)
- 统一 `drainRate()` 算法（历史 0.6 + 功率 0.4 权重融合）
- 通过 `sysctlbyname("hw.model")` 检测机型（MacBookAir/Pro，M1/M2/M3/M4/Intel 区分），返回不同基准放电速率
- **PowerSampler 集成**：每 30 个 tick 缓存到 `@Published cachedDrainRate` / `cachedChargeRate`，避免 View body 每 tick 全量扫描 DataStore（P0 性能问题）
- **UsageTab.swift / PopoverView.swift**：删除本地 `drainRate()`、`chargeRate()`、`machineBaselineDrainRate()`、`smoothedWattage()`、`chargeSegments()` 重复实现，改读 `sampler.cachedDrainRate` / `sampler.cachedChargeRate`

#### 批次 5：SyncTab 密码防抖 + SyncEngine 状态暴露 + BatteryBarApp syncEngine 移交（已完成）
- **syncEngine 移交 AppDelegate**：[BatteryBarApp.swift](Sources/BatteryBar/App/BatteryBarApp.swift) 从 `BatteryBarApp` 移到 `AppDelegate`，通过 `@EnvironmentObject` 注入 ContentView，SyncTab 用 `@ObservedObject` 共享同一实例
- **密码防抖**：[SyncTab.swift](Sources/BatteryBar/Views/SyncTab.swift) `schedulePasswordSave()` 用 `Task.sleep(0.6s)` + cancel 实现防抖，避免每次按键都触发 SecItem IPC
- **SyncEngine 状态显示**：`SyncState` 枚举（idle/syncing/success/failed）通过 `@Published` 暴露，SyncTab `syncStateLabel` 实时显示状态，"立即同步"按钮在 syncing 时禁用
- **预填密码**：SyncTab `onAppear` 从 Keychain 读取密码预填到 SecureField

#### 批次 6：powermetrics W 单位支持 + Helper 超时保护（已完成）
- **powermetrics 单位兼容**：[main.swift](Sources/BatteryBarHelper/main.swift) `parsePower(from:)` 支持 mW（最常见）/ uW / W 三种输出格式，正则 `(?<![mu])W` 确保不误匹配 mW/uW 中的 W
- **Helper 超时保护**：`DispatchQueue.global().asyncAfter(5s)` 超时 `terminate` 进程；`replyOnce` 防止超时后正常完成导致重复回调。原实现 `process.waitUntilExit()` 无超时，卡死会阻塞单线程 RunLoop 导致 Helper 永久不可用
- **不抽取 shared target**：HelperProtocol 双定义保留，主程序端 `@objc optional` 是有意兼容设计（旧 helper 缺方法时静默跳过而非崩溃）

#### 批次 7：代码质量清理（已完成）
- **onChange 旧语法**：[SyncTab.swift](Sources/BatteryBar/Views/SyncTab.swift) 5 处 `onChange(of:) { _ in ... }` 迁移到零参数新语法 `onChange(of:) { ... }`
- **双层 thickMaterial**：[BatteryBarApp.swift](Sources/BatteryBar/App/BatteryBarApp.swift) 移除 WindowGroup 那层 `.background(.thickMaterial)`，保留 ContentView 那层
- **未使用变量**：[PowerSampler.swift](Sources/BatteryBar/Data/PowerSampler.swift) 删除 `previousLevel`

#### 深色模式支持确认
- 状态栏文字 `textField.textColor = .labelColor`，系统外观切换时自动更新（浅色模式黑色，深色模式白色）
- 无需手动监听 `NSApplication.effectiveAppearance` 或 `NSDistributedNotificationCenter`

#### 编译修复（过程中发现）
- **SyncEngine async NSLock**：NSLock.lock/unlock 不能从 async 函数直接调用，封装到 `tryStartSyncing()` / `endSyncing()` 同步函数
- **BatteryReader static var 并发安全**：`_cachedHealthPercent` / `_healthCacheTime` 加 `nonisolated(unsafe)` 标注（已有 NSLock 保护）
- **NotificationManager override init**：NSObject 子类的 `private init()` 需要 `override` 关键字

#### 验证
- `swift build` 编译通过，无错误
- 仅剩预先存在的 `togglePopover` main actor isolation warning（与本次修改无关）
- 未运行应用（本轮为代码审查 + 修复，建议用户手动 smoke test）

---

### 2026-07-16 — 状态栏简化为纯百分比 + 清理图标方案 + Helper 默认关闭 + 代码审查

#### 状态栏从 SwiftUI 自绘图标改为纯文字百分比
- **改动文件**：[BatteryBarApp.swift](Sources/BatteryBar/App/BatteryBarApp.swift)
- **改动原因**：自绘图标方案折腾 12 个版本仍无法像素级复刻系统图标（私有 SF Symbol + 私有 SwiftUI init 无法第三方访问），用户最终决定放弃图标，改为纯文字百分比。
- **改动内容**：
  - 删除 MenuBarIconView / BatteryGlyphSwiftUI / BatteryFillShape 等所有图标渲染代码
  - 删除 NSHostingView 方案（嵌在 NSStatusBarButton 里不刷新，导致"只显示 1"的 bug）
  - 用 NSStatusBarButton + 子 NSTextField 显示文字（不用 button.title，避免系统 padding）
  - 充电时不显示预估时间（跟随系统逻辑，预估时间只在 popover/主窗口里）
  - **宽度精确控制**：`NSString.size(withAttributes:)` 测量文字精确宽度，`ceil(width) + 1pt` 余量设为 `statusItem.length`（固定值，非 variableLength），消除 NSStatusBarButton 系统默认 padding；textField 用 frame 直接定位（非 Auto Layout）
  - **+1pt 余量**：防止 `%` 等边缘字符被裁切（仅 `ceil` 会丢小数部分导致裁切）

#### 删除电池图标相关所有代码和资源
- **删除文件**：
  - `Sources/BatteryBar/MenuBar/BatteryIcon.swift`
  - `Sources/BatteryBar/Resources/` 目录（8 个 PDF/PNG）
  - `Sources/BatteryBarInject/` 目录（Inject.swift / ExtractSymbols.swift / constructor.m）
  - `inject.sh` / `inject_dump.sh`
  - 22 个 `extract_*.swift/.py`、`test_sf_*.swift`、`analyze_*.swift` 临时工具
  - `docs/BATTERY_ICON.md` 及两个 plans 文档
- **改动文件**：Package.swift（移除 BatteryBarInject target 和 Resources 资源声明）
- **改动原因**：图标方案全部放弃，相关代码和资源全部清理

#### 删除低电量模式功能
- **改动文件**：BatteryReader.swift / PowerSampler.swift / PopoverView.swift
- **改动内容**：移除 `isLowPowerMode` / `toggleLowPowerMode` / `readLowPowerMode` / HelperProtocol 里的 `setLowPowerMode`/`getLowPowerMode`
- **改动原因**：用户不再需要此功能

#### 删除隐藏系统电池图标功能
- **改动文件**：PopoverView.swift
- **改动内容**：移除"隐藏系统电池图标"按钮和相关逻辑
- **恢复方法**：如需恢复系统电池图标，执行 `defaults delete com.apple.controlcenter "NSStatusItem Visible Battery"` + `killall ControlCenter`

#### Helper 默认关闭 + 未开启时隐藏分项功耗
- **改动文件**：PowerSampler.swift / PowerTab.swift / PopoverView.swift
- **改动内容**：
  - Helper 默认关闭，PowerTab 有开关
  - `enableHelper()` 改为**安装成功后才写 UserDefaults**（修复密码取消/错误时开关仍显示开启的 bug）
  - 未开启时：Popover 和 PowerTab 隐藏 CPU/GPU/内存功耗行，只显示总功率
  - PowerTab 组件功耗明细卡片：未开启时显示"开启 Helper 后显示分项功耗"提示，不再显示"其他=总功耗"的无意义行

#### 修复重复 PowerSampler 实例
- **改动文件**：BatteryBarApp.swift
- **改动原因**：`BatteryBarApp` 的 `@StateObject` 和 `AppDelegate` 各创建一个 PowerSampler，导致双倍 IOKit 读取、双倍 DataStore 写入、循环统计重复记录
- **改动内容**：AppDelegate 持有唯一实例，主窗口通过 `appDelegate.sampler` 共享

#### 代码审查清理
- **删除文件**：`Sources/BatteryBar/Views/HealthTab.swift`（死代码，从未被使用）
- **改动文件**：DataStore.swift（删除空的 `applyDailyResetIfNeeded()`）、PowerSampler.swift（删除未用 `import AppKit`）、UsageTab.swift（删除未用 `formatRelativeMinutes`）、TimeRange.swift（更新注释）

#### 清理旧 Helper 残留
- 用 osascript 清理 `/Library/PrivilegedHelperTools/com.batterybar.helper` 和 `/Library/LaunchDaemons/com.batterybar.helper.plist`
- `launchctl bootout` 停止常驻进程

#### SIP 说明
- 用户曾关闭 SIP 用于逆向 ControlCenter 提取系统电池图标
- **所有相关操作均可逆**：dylib 注入是运行时 `lldb dlopen`，重启即消失；`/tmp/batterybar_*` 缓存已清理
- 用户已重新开启 SIP

#### 验证
- `swift build` 编译通过
- `bash build-app.sh` 成功
- App 启动成功，状态栏显示纯百分比

---

### 历史变更日志（按时间倒序）

> 以下为早期变更记录，仅保留摘要，详见 git history。

#### 2026-07-14（第七轮）— WebDAV 坚果云默认 + 时间戳同步 + 状态栏图标重做
- WebDAV 默认地址改为坚果云
- 时间戳同步（last-write-wins）
- 状态栏图标 CoreGraphics 重做（已删除）

#### 2026-07-14（第六轮）— 弹窗关闭 + 循环趋势图重做 + 功耗组件曲线 + 内存功耗
- 弹窗点击查看详情后自动关闭
- 循环趋势图改为"续航能力趋势"
- BatterySnapshot 扩展组件功率字段
- 功耗趋势图加组件曲线勾选
- Helper 读取内存功耗（版本 3.0）

#### 2026-07-14（第五轮）— 充放电周期逻辑重写 + 续航预估算法 + 崩溃修复
- 拔电立即重置统计
- 短时间重插拔平滑（30 秒阈值）
- 满电判断逻辑修复（`isPluggedIn && level >= 100`）
- 耗电曲线从拔电开始绘制
- 续航预估算法改进（排除充电快照、5% 截止保护、滑动窗口中位数）
- 拔电初期预估算法（机型基准 10%/h）
- Range 崩溃修复（动态窗口 2-5）
- 使用时间统计按充放电周期重置
- Chart 编译器超时修复（拆分函数）

#### 2026-07-14（第四轮）— 自主验证 + 电池信息/适配器/窗口多开修复
- 设备名称修复（`MacBook Air (Apple M1) · bq20z451`）
- 制造商兜底（"Apple Inc."）
- 序列号字段名修复（`Serial` 而非 `SerialNumber`）
- 制造日期置 nil（Apple 硬件限制）
- 充电协议/适配器功率读取修复（AppleSmartBattery 节点 AdapterDetails）
- CPU/GPU 功耗读取验证
- 窗口多开/前台问题修复
- Helper 版本检测与自动更新
- readComponentPower 超时保护

#### 2026-07-14（第三轮）— 功耗读取完善 + 充电估算优化 + 电池信息修复
- CPU/GPU 功耗通过 XPC helper 读取
- 屏幕功耗估算
- 制造商/序列号修复
- 充电协议/适配器信息读取
- 充电预计时间优化（5% 分段叠加）
- 满电/离电状态逻辑优化
- PowerTab 组件功耗明细卡片
- Dock 图标显示
- 电量曲线按充电周期分段
- CycleTracker 平均瓦数修复
- SyncEngine 自动同步接线
- 删除死代码 MainView.swift
- print 清理为 os.Logger
- 引入单元测试

#### 2026-07-14（第二轮）— DataStore 数据竞争 + 时长统计 + Charts 交互
- DataStore 数据竞争修复（queue.sync 包装访问器）
- 时长统计修复（SleepWatcher 接线、持久化、按日重置）
- PowerSampler 修复（start 幂等、refreshInterval 接通）
- 电池信息读取完善（manufactureDate、deviceName、chemistry）
- Charts 交互增强（chartXSelection、时间范围选择器、Tab 实时刷新）
- WebDAV 每设备一文件
- 构建脚本与签名清理
