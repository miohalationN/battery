# IMPLEMENTATION_HANDOFF — 2026-08-23 信息架构 / 性能边界 / 功率口径 / 追加存储重构

> 执行 Agent 移交文档。供 assurance/review agent 独立验证。
> 基线提交：`be5f3ebfbdef0b97709081aeab04451e4b497ce9`（已安装基线 `/Users/mio/Applications/BatteryBar.app`）
> 本文件随实现提交；CI、安装与实机验收证据在对应步骤完成后补充更新（docs-only 提交不触发构建）。

---

## 一、变更范围

草案（10 文件 +238/-55，未编译）经审查后修正、重组并补齐为完整实现。取舍说明：

| 草案内容 | 处置 | 理由 |
|----------|------|------|
| @Observable PowerSampler + `@Environment(PowerSampler.self)` | **保留** | 属性级失效是本次性能目标的核心机制；macOS 14 支持 |
| BatteryReader 遥测优先级链 + normalizedTelemetryPower | **保留** | 与本机 IORegistry 实测吻合（见 §三） |
| v1 快照 decodeIfPresent 兼容 | **保留** | 符合口径要求；但成员构造器默认值有缺陷（见下） |
| 成员构造器 `systemPowerAvailable: Bool = true` 默认 | **修正** → `Bool? = nil` 按 `!isCharging` 推导 | 原默认会让旧调用点构造的充电快照污染系统负载统计（与解码路径规则不一致） |
| DataStore JSONL journal + retainedSnapshots(24h/1500) | **保留** + 注入目录/测试钩子 | 满足"每分钟不全量重写"；不可注入则无法单测迁移/坏行 |
| SleepWatcher screensDidSleep/screensDidWake | **保留** | 即规格要求 |
| 空 staticInfoObserver（body 为注释） | **删除** | 规格明确要求删空 observer；shouldPublishMetadata 已保证 ≤1s 内属性级传播 |
| WebDAV 只加上传字段 | **补齐下载端** | 抽出 `BatterySnapshot.from(remoteJSON:)` 双端共用并对旧格式推导 |
| 组件新鲜度 | **新增** `lastComponentPowerAt` | 规格要求 >30s 陈旧即停显占比 |
| 页面 IA / LazyVStack / 阴影清理 / 归一化趋势 | **全新实现** | 草案完全未涉及 |

## 二、关键设计不变量

1. **功率双口径**：`wattage` ≡ 系统负载；`batteryPower` ≡ 电池包充放功率绝对值。
   接电且无遥测时系统负载不可用（`systemLoad == nil`），绝不显示充电功率冒充。
2. **统计隔离**：系统负载统计/曲线只纳入 `systemPowerAvailable == true` 的快照；
   v1 充电快照（available=false）只参与电池侧统计。
3. **失效边界**：页面根视图只读低频字段（level/isCharging/externalConnected/currentInfo/
   helperEnabled）；每秒瓦数只在英雄卡/读数行小视图内消费；历史分析模型
   （UsageSessionModel / PowerTab rangeStats / CycleTab reload）仅由快照通知或范围切换触发；
   Chart 一律 `.equatable()` 隔离。
4. **追加日志**：`saveSnapshot` 无条件 append 一行；内存侧过期行立即收敛，文件侧延迟清理，
   累计 ≥60 条（≈1 小时量）才原子 compact；mark synced / 远端 merge 即时 compact；
   末尾半行加载时跳过；v1 `snapshots.json` 迁移后保留不删。
   ⚠️ 首轮安装实测曾发现稳态缺陷（见 §九），已修复并有回归测试覆盖。
5. **屏幕状态**：`screenOn = !isSleeping && !screensSleeping`；显示器关闭但醒着的分钟计入「屏幕关闭/休眠」。

## 三、本机数据佐证（实现前实测）

```
ioreg -r -c AppleSmartBattery：
PowerTelemetryData = { SystemLoad=14071, SystemPowerIn=12240,
                       BatteryPower=18446744073709549785 (UInt64 回绕哨兵), ... }
NSNumber(UInt64 回绕) as? Double → nil（被拒绝）；整数 mW as? Double → 正常转换
```
接电满电场景：SystemLoad≈14W（真实负载），而电池净功率≈0.x W —— 证实旧口径错误与本修复方向。

## 四、本地验证记录（CLT 环境）

环境：CLT only（swiftc 6.4, macOS 27 SDK），无 Xcode → SwiftUI 宏插件缺失，
全量 `swift build` 无法越过 @State 展开（既有已知环境限制，非代码失败）。

1. **非视图层整体 typecheck 通过**：Models+Calc+Data+Sync 全部源码 + 全部测试文件
   合成单一模块 `swiftc -typecheck -swift-version 6`（含 `-load-plugin-library libTestingMacros.dylib`）→ 0 error。
   该过程抓出并修复：NormalizedRecord Equatable 缺失、测试缺 try 等 6 处问题。
2. **全部改动 Swift 文件 `xcrun swiftc -parse` 通过**（0 error）。
3. 过滤掉宏插件缺失类错误后的全量 swift build 输出无其他诊断
   （期间抓出 SessionChartPlot Equatable 主 actor 隔离错误并修复为 `@MainActor Equatable`）。

## 五、测试清单（由 GitHub Actions Xcode 环境执行）

新增：
- `TelemetryNormalizationTests`：13759mW→13.759W；12.5 保持；nil/负/NaN/∞/UInt64 哨兵/超范围→0
- `SnapshotCompatTests`：v1 充电快照 available=false 且 systemLoad=nil；v1 离电快照=估算负载；
  v2 Codable 往返；成员构造器按 isCharging 推导；toJSON/from(remoteJSON:) 往返与新键集合；
  远端旧格式推导；畸形行拒绝；保留窗口（24h 裁剪/未来点拒绝/±5min 容忍/1500 硬上限/排序）
- `DataStoreJournalTests`（注入临时目录）：legacy 数组迁移且旧文件保留；逐条追加不重写；
  末尾半行跳过其余可载；中间坏行容忍；markSynced compact 后 dirty=false 持久化且内容一致；
  远端合并 timestamp 胜出且不入 dirty；超窗数据加载即裁剪
- `OffPowerRecordAnalyzerTests`：展示过滤（<5min/<1% 剔除）；不同降幅可比
  （100→10@5h vs 50→30@2h 的 %/h 与折算满电续航）；<5% 或 <15min 不进趋势；样本不足返回空
- `DrainRateCalculatorTests` 新增：wattage=0/batteryPower=10 反例证明使用 batteryPower；
  AC 快照整体排除

回归保持：CycleTrackerTests / ChartDownsamplerTests / SyncConfigTests / WebDAVResponseParserTests /
BatterySnapshotTests / DrainRateCalculatorTests 原有用例不改语义。

## 六、CI 构建产物与实机验证记录

### 第一轮（提交 f4b8302，run 32595255556）
- 结论：**test 失败**（7 issues）→ 定位为 3 处测试夹具错误 + 1 处真实健壮性缺陷（空 journal 不回退 legacy），修复于提交 cf2e345
- 运行时验证（已安装 cf2e345 产物）抓出**稳态每分钟重写缺陷**：24h 窗口边界使
  `retained.count != snapshots.count` 每分钟成立 → 每分钟一次全量重写。
  证据：70s 观察窗内行数不变、文件被原子替换（size +13B、前缀哈希变化）。

### 第二轮（最终，全部通过）
- 触发提交：`686cb60`（Compact snapshot journal on accumulated expiries, not every minute）
- Run URL：https://github.com/miohalationN/battery/actions/runs/32596337196
- 结果：build ✓ + test ✓ —— `Test run with 74 tests in 11 suites passed`
- Artifact sha256：
  - `Contents/MacOS/BatteryBar`: `84f47380a8a44d0d182e5112b9d8b00382b377f275720c1176a3cdadb48348b8`
  - `Contents/Resources/BatteryBarHelper`: `d498d03c81827dc558203989f7f433cabfa90b307948b21f227b45b30623d5e1`
- 安装：ditto 至 `/Users/mio/Applications/BatteryBar.app`；
  `codesign --verify --deep --strict` 通过；安装后二进制 sha256 与 artifact 完全一致
- 数据备份（第二轮安装前）：`~/Library/Application Support/BatteryBar-backup-cf2e345`
- 第二轮运行时验证（安装后 130s 观察窗）：
  - `snapshots.jsonl` inode 不变、行数 1438→1440 —— 稳态纯追加、零重写 ✓
  - BatteryBar 进程 CPU 0.0%（不劣于基线 0.1%）✓
  - 零 `powermetrics` 进程（Helper 关闭，defaults BatteryBarHelperEnabled=0）✓

### 实机验证（第一轮安装期间采集，口径与行为证据仍然有效）
- 安装前数据备份：`~/Library/Application Support/BatteryBar-backup-be5f3eb`（复制，原数据未动）
- 旧 app 备份：`~/.Trash/BatteryBar-be5f3eb-040514.app`
- 迁移验证：启动即生成 `snapshots.jsonl`（1437 行），legacy `snapshots.json` 原样保留
- 功率口径：接电满电新快照 `wattage=13.6~13.8W（遥测实测）、batteryPower=0.28W、estimated=false` ——电池净功率不再冒充系统负载 ✓
- Helper 关闭（defaults=0）：观察期内零 `powermetrics` 进程 ✓；系统旧 Helper 未删除/未改动
- 静止 CPU：0.1%（与基线持平）✓

## 七、页面视觉验收

按执行约定，截图与视觉分析由后续验收模型独立完成；
本 agent 已确认主窗口可从状态栏打开，三页数据通路（快照通知 → 模型 → 图表）由单测覆盖。

## 八、遗留限制

1. 本地 CLT 无 Xcode，SwiftUI 视图层完整类型检查只能由 CI 完成（项目固有约束）。
2. ad-hoc 签名下 Helper 调用方校验只能到 bundle id 粒度（既有限制，未在本任务范围内改变）。
3. `normalizedTelemetryPower` 以 >250 判定 mW/W 单位，属启发式；对笔记本合理功率域（<250W）安全。
4. journal 存在时即使解码行数为 0 也回退 legacy（retention 过滤保证不复活过期数据）；
   极端情况下若 journal 与 legacy 同时损坏，可能丢失窗口内历史——已由 .bak/备份流程缓解。

## 九、执行 Agent 自审发现（可操作项）

| severity | 发现 | 处置 |
|----------|------|------|
| high | 稳态下 24h 窗口边界使每分钟新样本恰好挤出一条过期记录，原「差值≠0 即重写」策略退化为每分钟全量重写（首轮安装实测证据：行数不变、文件原子替换） | 已修复：追加无条件化 + 过期行累计 ≥60 才 compact；回归测试 `steadyStateExpirationCompactsOnlyAfterThreshold` 复现并验证 |
| medium | 空 journal（compact 到空或全部损坏）时不回退 legacy，可能静默丢历史 | 已修复：0 有效行且 legacy 存在时回退；测试 `emptyJournalFallsBackToLegacy` 覆盖 |
