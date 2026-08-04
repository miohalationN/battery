# BatteryBar — macOS 菜单栏电池监控应用

## 一、产品定位

一款 macOS 菜单栏常驻应用，将 iPhone 上「设置 → 电池」的核心体验搬到 Mac：自上次充电以来的使用时长、耗电曲线、电池健康、实时功耗，一目了然。状态栏图标与系统电池 1:1 一致，百分比直接嵌入图标内部。遵循 macOS 26 Liquid Glass 设计规范。

---

## 二、功能清单

### 2.1 状态栏（Menu Bar）

| 项目 | 说明 |
|------|------|
| 电池图标 | 用 Canvas 绘制，与系统 `NSBattery` 图标像素级一致：圆角矩形外壳 + 右侧小凸起 + 内部填充（按电量百分比裁剪，充电时绿色渐变） |
| 百分比数字 | 嵌入图标内部，居中显示，字体 SF Pro Rounded Medium，字号自适应图标高度（~11pt），颜色随填充对比度自动切换黑/白 |
| 充电指示 | 充电中时图标内部填充为绿色，叠加 ⚡ 符号或闪电路径 |
| 低电量 | ≤20% 填充变红，≤10% 闪烁（1s 周期） |
| 点击行为 | 点击展开 Popover 面板；Option+点击打开主窗口 |
| 右键菜单 | 快捷操作：打开主窗口、偏好设置、关于、退出 |

### 2.2 Popover 面板（点击状态栏图标展开）

**布局：** 宽度 320pt，高度自适应，Liquid Glass 毛玻璃背景

```
┌─────────────────────────────────────┐
│  🔋 78%  充电中 · 45W 输入          │  ← 顶部摘要
│  ─────────────────────────────────  │
│  自上次充电以来                      │
│  ├ 亮屏   3h 42m                    │
│  ├ 休眠   1h 15m                    │
│  └ 使用   4h 57m                    │
│  ─────────────────────────────────  │
│  实时功耗                           │
│  ├ 系统总功耗    12.4 W             │
│  ├ CPU           5.2 W              │
│  ├ GPU           2.1 W              │
│  └ 显示器        3.8 W              │
│  ─────────────────────────────────  │
│  电池健康                           │
│  ├ 循环次数      287 次             │
│  ├ 最大容量      5,200 / 5,100 mAh │
│  ├ 设计容量      5,100 mAh         │
│  ├ 电池温度      32.4°C             │
│  └ 健康度        100%               │
│  ─────────────────────────────────  │
│  本循环预估寿命                      │
│  ├ 已用 4h57m → 剩余 ~3h12m        │
│  └ 预计总续航  ~8h09m               │
│  ─────────────────────────────────  │
│  [ 打开详细视图 ]   [ 偏好设置 ]     │
└─────────────────────────────────────┘
```

### 2.3 主窗口（详细视图）

**窗口规格：** 720×540pt，可调整，Liquid Glass 背景，圆角 16pt

#### Tab 1：使用记录

- **耗电曲线图**（Swift Charts）
  - X 轴：自上次充电以来的时间（HH:MM）
  - Y 轴：电量百分比（0-100%）
  - 折线图，充电区间用绿色填充，放电区间用蓝色渐变填充
  - 支持鼠标悬停查看精确数值
  - 采样间隔：每 60 秒记录一次，保留最近 24h 数据
- **时长统计卡片**
  - 亮屏时长、休眠时长、总使用时长
  - 各阶段平均耗电速率（%/h）
- **本次循环预测**
  - 基于当前耗电速率推算剩余续航
  - 基于历史同场景数据推算总续航

#### Tab 2：电池健康

- **健康仪表盘**
  - 圆环图显示当前容量 / 设计容量
  - 循环次数 + 寿命条（参考 Apple 标准：1000 次循环后 ≥80%）
- **温度实时曲线**（最近 1h）
- **电池信息表**
  - 制造商、型号、序列号、化学成分（Li-ion）
  - 设计容量、当前最大容量、当前电量
  - 电压、电流、功率

#### Tab 3：循环统计

- **循环列表**
  - 每次完整循环（100%→0% 等效）记录
  - 日期、持续时长、起止电量、平均功耗
- **循环寿命趋势图**
  - X 轴：循环序号，Y 轴：该循环实际可用容量
  - 用于判断电池衰减趋势
- **统计摘要**
  - 平均每次循环续航
  - 最长 / 最短循环续航
  - 容量衰减率（mAh/循环）

#### Tab 4：组件功耗（可选，需 IOReport 权限）

- CPU、GPU、显示器、Wi-Fi、蓝牙等分项功耗
- 实时柱状图 + 历史趋势

#### Tab 5：同步

- **WebDAV 服务器配置**
  - 服务器地址、端口、路径、用户名、密码（存 Keychain）
  - 测试连接按钮
  - 支持 Nextcloud / 坚果云 / 任意 WebDAV 服务
- **同步策略**
  - 本地优先（Local-first）：所有数据先写本地 SwiftData
  - 手动同步 + 自动同步（可配置间隔：15min / 1h / 6h）
  - 同步方向：双向 / 仅上传 / 仅下载
- **同步内容**
  - 电池采样快照（BatterySnapshot）
  - 循环记录（ChargeCycle）
  - 偏好设置
- **同步状态**
  - 最后同步时间、下次同步倒计时
  - 同步进度条、冲突提示
  - 同步日志（最近 50 条）

---

## 三、技术架构

### 3.1 技术栈

| 层 | 选型 | 理由 |
|----|------|------|
| UI | SwiftUI + MenuBarExtra (macOS 13+) | 原生菜单栏支持，Liquid Glass 原生适配 |
| 图表 | Swift Charts | 系统框架，Liquid Glass 风格统一 |
| 数据持久化 | SwiftData | 轻量，Swift 原生，够用 |
| 电池数据 | IOKit (IOPSCopyPowerSourcesInfo + IORegistry) | 系统 API，无需额外权限 |
| 功耗细分 | IOReport | 可读取 CPU/GPU/显示器分项功耗 |
| 电源事件 | NSWorkspace + IORegisterForSystemPower | 监听休眠/唤醒/充电状态变化 |
| 定时器 | Timer + RunLoop | 每 60s 采样一次电池数据 |
| WebDAV 同步 | WebDAV-Swift (SPM) 或自建 URLSession+XMLParser | 轻量 WebDAV 客户端，支持 Nextcloud/坚果云 |
| 密码存储 | Keychain Services | WebDAV 凭据安全存储 |

### 3.2 项目结构

```
BatteryBar/
├── App/
│   ├── BatteryBarApp.swift          # 入口，MenuBarExtra 注册
│   └── AppDelegate.swift            # 电源事件监听
├── MenuBar/
│   ├── BatteryIcon.swift            # Canvas 绘制系统风格电池图标
│   ├── StatusBarController.swift    # 状态栏管理
│   └── PopoverView.swift            # 点击展开的概览面板
├── Views/
│   ├── MainView.swift               # 主窗口 TabView
│   ├── UsageTab.swift               # 使用记录 Tab
│   ├── HealthTab.swift              # 电池健康 Tab
│   ├── CycleTab.swift               # 循环统计 Tab
│   ├── PowerTab.swift               # 组件功耗 Tab
│   └── SyncTab.swift                # 同步设置 Tab
├── Data/
│   ├── BatteryReader.swift          # IOKit 数据读取封装
│   ├── PowerSampler.swift           # 定时采样 + IOReport
│   ├── SleepWatcher.swift           # 休眠/唤醒事件监听
│   └── CycleTracker.swift           # 循环检测与记录
├── Sync/
│   ├── WebDAVClient.swift           # WebDAV 协议实现（PROPFIND/PUT/GET/DELETE）
│   ├── SyncEngine.swift             # 同步调度、冲突解决、增量同步
│   ├── SyncModels.swift             # 同步元数据（时间戳、哈希、版本号）
│   └── KeychainHelper.swift         # Keychain 读写封装
├── Models/
│   ├── BatterySnapshot.swift        # SwiftData: 采样快照
│   ├── ChargeCycle.swift            # SwiftData: 循环记录
│   └── BatteryInfo.swift            # 电池静态信息
├── Utilities/
│   ├── LiquidGlassModifier.swift    # Liquid Glass 样式封装
│   └── NumberFormatter+.swift       # 数字格式化
└── Resources/
    └── Assets.xcassets              # 图标资源
```

### 3.3 关键实现

#### 状态栏图标

```swift
// BatteryIcon.swift — 核心绘制逻辑
struct BatteryIcon: View {
    let level: Double      // 0.0 ~ 1.0
    let isCharging: Bool
    let isLow: Bool

    var body: some View {
        Canvas { context, size in
            // 1. 外壳：圆角矩形 22×11，线宽 1.5
            // 2. 正极凸起：右侧 2×4 圆角矩形
            // 3. 内部填充：按 level 裁剪，充电时绿色
            // 4. 百分比文字：居中，SF Pro Rounded Medium 11pt
            // 5. 低电量红色 / 充电闪电符号
        }
        .frame(width: 28, height: 14)
    }
}
```

#### 电池数据读取

```swift
// BatteryReader.swift
class BatteryReader {
    // IOPSCopyPowerSourcesInfo → 电量、充电状态、剩余时间
    // IORegistry → 循环次数、设计容量、最大容量、温度、电压、电流
    // 计算实时功率 P = V × I
}
```

#### 采样与持久化

```swift
// PowerSampler.swift
class PowerSampler {
    let timer = Timer.publish(every: 60, on: .main, in: .common)

    func sample() {
        let snapshot = BatterySnapshot(
            timestamp: Date(),
            level: reader.level,
            isCharging: reader.isCharging,
            wattage: reader.wattage,
            temperature: reader.temperature,
            screenOn: ScreenState.isScreenOn
        )
        modelContext.insert(snapshot)
    }
}
```

#### 循环检测

```swift
// CycleTracker.swift
// 逻辑：检测充电状态从 charging → not-charging 的转换
// 当转换发生时，记录本次循环的起止时间、起止电量、总耗电量
// 100%→0% 为一个完整循环；多次部分充放累计 100% 也算一个等效循环
```

### 3.4 WebDAV 同步架构

#### 同步协议

基于 HTTP 的 WebDAV 扩展方法，使用 Foundation `URLSession` + `XMLParser` 自建轻量客户端（不引入第三方依赖）。核心操作：

| WebDAV 方法 | 用途 |
|-------------|------|
| `PROPFIND` | 列出远程目录、获取文件修改时间 |
| `GET` | 下载数据文件 |
| `PUT` | 上传数据文件 |
| `MKCOL` | 创建同步目录 |
| `DELETE` | 删除过期数据 |

#### 远程目录结构

```
/BatteryBar/
├── snapshots/
│   ├── 2026-07-12.jsonl.gz    # 按天分文件，gzip 压缩
│   ├── 2026-07-11.jsonl.gz
│   └── ...
├── cycles/
│   └── cycles.json            # 循环记录（小文件，全量同步）
├── settings.json              # 偏好设置
└── .sync-meta.json            # 同步元数据（设备ID、最后同步时间）
```

#### 同步策略

```
1. 本地写入 SwiftData（立即）
2. 标记 dirty flag（待同步）
3. 同步定时器触发 / 手动触发
4. 增量上传：只上传 dirty 记录
5. 冲突解决：last-write-wins（以 timestamp 为准）
6. 下载合并：按 record id 去重，新记录插入本地
```

#### 数据格式

每条采样记录序列化为 JSON Lines（每行一条 JSON），按天分文件：

```json
{"id":"uuid","ts":1720780800,"level":78.5,"charging":true,"watt":45.2,"temp":32.4,"screen":true}
```

gzip 压缩后上传，单日文件约 50KB（1440 条 × ~80 字节 → 压缩后 ~15KB）。

### 3.5 Liquid Glass 适配

- 所有面板使用 `.glassEffect()` 或 `.background(.ultraThinMaterial)`
- Popover 和主窗口使用圆角 16pt + 阴影
- 卡片内使用 `.padding(12)` + `.clipShape(RoundedRectangle(cornerRadius: 10))`
- 颜色方案跟随系统（亮/暗），不自定义主题
- 图标使用 SF Symbols 6（macOS 26 新增的电池相关符号）
- 字体层级：标题 `.headline`，数据 `.title2.monospacedDigit()`，标签 `.caption`

---

## 四、数据模型

### BatterySnapshot（每 60s 一条）

```
id: UUID                # 同步用唯一标识
timestamp: Date
level: Double           // 0~100
isCharging: Bool
wattage: Double         // 瓦特
temperature: Double     // 摄氏度
screenOn: Bool          // 亮屏/休眠标记
dirty: Bool             // 待同步标记（本地新增/修改后置 true，同步完成后置 false）
```

### ChargeCycle

```
id: UUID
startDate: Date
endDate: Date
startLevel: Double
endLevel: Double
totalEnergy: Double     // mAh
averageWattage: Double
duration: TimeInterval
dirty: Bool             // 待同步标记
```

### BatteryInfo（静态，不持久化）

```
designCapacity: Int     // mAh
maxCapacity: Int        // mAh
cycleCount: Int
manufactureDate: Date
serialNumber: String
manufacturer: String
```

### SyncConfig（SwiftData，单例）

```
isEnabled: Bool
serverURL: String       // WebDAV 服务器地址
username: String
remotePath: String      // 远程目录，默认 /BatteryBar
syncInterval: Enum      // 15min / 1h / 6h / manual
syncDirection: Enum     // bidirectional / uploadOnly / downloadOnly
lastSyncAt: Date?
deviceID: String        // 设备唯一标识，用于多设备去重
```

---

## 五、权限与兼容性

| 项目 | 要求 |
|------|------|
| 最低系统 | macOS 14.0（Sonnet）—— MenuBarExtra + SwiftData |
| 推荐系统 | macOS 26.0 —— Liquid Glass 完整支持 |
| 权限 | 无特殊权限要求，IOKit 读取电池数据为用户态操作 |
| App Sandbox | 开启，仅需 `com.apple.security.app-sandbox` |
| 签名 | Developer ID 签名 + 公证（发布时） |
| 后台运行 | `LSUIElement = true`，无 Dock 图标 |

---

## 六、非功能需求

- **性能：** CPU 占用 < 1%，内存 < 50MB，采样线程不阻塞主线程
- **电量：** 自身功耗 < 0.5W，不能比监控的电量消耗还多
- **存储：** 24h 采样数据约 1440 条记录，占用 < 1MB；历史数据按天自动清理
- **启动：** 冷启动 < 1s，状态栏图标立即显示
- **隐私：** 不联网（WebDAV 同步为用户主动配置，不配置则零网络请求），不收集任何数据，所有数据本地存储

---

## 七、不做（YAGNI）

- ❌ 通知/提醒功能（系统已有低电量提醒）
- ❌ 多设备支持（iPhone/Apple Watch 电量）
- ❌ 电池校准工具
- ❌ 自定义主题/皮肤
- ❌ 导出报告（除非用户明确要求）
- ❌ Widget（v1 不做，MenuBarExtra 够用）
- ❌ 菜单栏图表（v1 只显示图标+百分比）

---

## 八、参考项目

### macOS 电池监控类

| 项目 | 亮点 | 参考价值 |
|------|------|----------|
| [ChargeWatching](https://github.com/TY-teo/ChargeWatching) | SwiftUI 菜单栏，三路功率显示（电池/系统/适配器），SQLite 存储历史，IOKit `AppleSmartBattery` + `PowerTelemetryData` 读取，1Hz 采样 | 功率计算方式（V×I）、菜单栏实现、历史数据存储 |
| [MacoPowerMonitor](https://github.com/LCYLYM/MacoPowerMonitor) | SwiftUI + AppKit，玻璃面板，双向功率视图，`ioreg` + `system_profiler` + `IOPowerSources` 多数据源，本地 JSON 历史 | 数据源选择、面板 UI 设计、隐私优先 |
| [batt](https://github.com/charlie0129/batt) | Go 写的充电限制器，SMC 直接读写，Client-Daemon 架构，菜单栏 GUI | SMC 数据读取方式、daemon 架构思路 |
| [coconutBattery](https://coconut-flavour.com) | 老牌工具，循环次数/容量/温度/Wi-Fi 多设备查看 | 数据展示维度参考 |

### WebDAV 同步类

| 项目 | 亮点 | 参考价值 |
|------|------|----------|
| [WebDAV-Swift](https://github.com/skjiisa/WebDAV-Swift) (⭐79) | 纯 Swift WebDAV 客户端，内置缓存，支持 Nextcloud，SPM 集成 | 可直接作为依赖引入，或参考其 PROPFIND/PUT/GET 实现 |
| [FileProvider](https://github.com/amosavian/FileProvider) (⭐116) | 统一文件操作接口，支持 WebDAV/iCloud/Dropbox/OneDrive/S3 | 架构参考：统一 FileProvider 协议，WebDAV 只是其中一个 backend |
| [PandaNote](https://github.com/Panway/PandaNote) (⭐117) | Markdown 笔记应用，支持 WebDAV 同步 | 同步策略、冲突处理参考 |

### 关键技术参考

- **IOKit 电池数据读取**：`IOPSCopyPowerSourcesInfo()` + `IORegistryEntryCreateCFProperty("AppleSmartBattery")` — ChargeWatching 和 MacoPowerMonitor 都用这个方案
- **功率计算**：`P = Voltage(mV) × InstantAmperage(mA) / 1,000,000` — ChargeWatching 验证过聚合字段不可靠，必须用原始 V×I
- **WebDAV 协议**：本质是 HTTP + 扩展方法（PROPFIND/MKCOL），用 `URLSession` + `XMLParser` 可自建，无需第三方依赖
- **同步数据格式**：JSON Lines + gzip 压缩，按天分文件，单文件小适合增量同步
