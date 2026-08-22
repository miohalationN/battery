# IMPLEMENTATION_HANDOFF — 电源状态语义修复（isCharging ≠ 是否接电）

> 执行 Agent 移交文档，供 assurance/review agent 独立验证。
> 本轮基线：`e199e5922954204832dd82e0d4f38cfe08a524c4`（origin/main 同步且 clean）。
> 上一轮移交见 git 历史（be5f3eb→e199e59 的重构与本文件旧版本）。

---

## 一、问题定义（验收失败项）

macOS 满电保持、优化充电暂停、80% 充电上限均呈现 `externalConnected=true, isCharging=false`。
上一版代码把 isCharging 当作"是否接电"，导致：

- 实机 `snapshots.jsonl` 中 **1190 条** level≥99、未充电、亮屏、估算 0–3W 的记录
  （v2 格式，无电源字段）被标为"可用离电负载"；
- 6h 负载均值被拉至 2.45W，同期遥测实测均值约 11W（本机安装实例实测：
  available 平均 2.45W/243 点、遥测子集 10.94W/41 点）；
- CycleTracker 会把整段接电静置记为"离电使用"；DrainRateCalculator 与
  UsageSessionModel 存在同源错误。

## 二、schema 兼容策略

- 快照新增 `externalConnected: Bool?`。**键存在与否即可靠区分格式**（provenance）：
  - v1：无 batteryPower/systemPowerAvailable/externalConnected；
  - v2：有估算标记、无 externalConnected；
  - v3：显式 externalConnected（true/false）。
- 编码用 `encodeIfPresent`：nil 不写键 → 永不伪造电源状态；解码 `decodeIfPresent`
  → v1/v2/v3 全部可读，已迁移进 journal 的无键点同样按 unknown 处理。
- WebDAV JSONL 新增 `ext` 字段；`toJSON` 仅在已知时写出；`from(remoteJSON:)`
  对远端旧格式按同一保守规则推导，双端兼容。
- legacy 备份与用户历史数据一律不删除、不改写。

## 三、污染数据的保守隔离（不伪造、只隔离）

`trustedSystemLoad` 规则：
1. 实测遥测（systemPowerIsEstimated == false）独立可信——无论电源状态是否已知，
   一律保留进系统负载统计/曲线（含 v2 实测点）；
2. 估算负载仅在 `externalConnected == false` 时可信；
3. 来源未知 + 估算（即全部历史污染形态）→ 排除出系统负载统计、DrainRate 历史与
   离电时段统计。数据仍在 journal 中完整保留，只是不参与统计。

状态机统一改为插拔语义（PowerSourceState 三态：charging / onPowerNotCharging / onBattery）：

| 组件 | 修改 |
|------|------|
| CycleTracker | `update(isPluggedIn:level:batteryPower:)`；接电→离电开始记录，离电→接电结束；暂停充电数小时零记录 |
| PowerSampler | sampleStorage 持久化 externalConnected 并传 isPluggedIn 给 CycleTracker；cachedDrainRate 仅离电计算 |
| DrainRateCalculator | `isOnBattery=false` 直接返回 0（不显示续航预估）；onBatterySegments/smoothedWattage 只认 externalConnected==false 的样本 |
| UsageSessionModel | 按 externalConnected 分段并排除未知点；「上次充电摘要」需正电量变化 ≥1% 且时长 ≥5 分钟，否则显示「暂无有效充电记录」（禁止 100%→100% + 已充入 0% 却带平均功率的假摘要）；充电摘要平均功率仅取 isCharging 样本（暂停期 ≈0W 不稀释） |
| UsageTab 英雄卡 | 四态：满电接电 / 正在充电 / 已接电未充电 / 离电；仅离电显示续航预估 |
| PopoverView | 与主窗口共用 PowerSourceState 定义 |

## 四、性能收口

- HealthMetricsGrid、BatteryDetailSection 拆成独立观察子视图：温度/电压/电流变化
  只失效对应小块，页面根视图不再因此重建。
- 根视图依赖收敛为 currentLevel / powerSourceState / session 模型等低频字段。
- 未新增任何持续 blur、阴影、动画或高频 Date 驱动刷新。

## 五、测试反例清单（全部落地为回归测试）

- `legacyPluggedNotChargingPollutionRejected`：v2 形态（ext 缺失、level=100、!charging、估算 2.1W）→ trustedSystemLoad=nil、非离电；
- `explicitExternalConnectedDrivesTrust`：ext=true 同形态排除；ext=false 估算负载可用；遥测（estimated=false）无论 ext 是否缺失都保留；
- `pausedChargingOnPowerProducesNoRecord` / `eightyPercentLimitThenRealUnplug`：暂停数小时零离电记录；真正拔电后按插拔起点记录；
- `drainRateReturnsZeroWhenNotOnBattery` / `pausedChargingPointsExcludedFromHistory` / `unknownSourceEstimatedPollutionExcluded`：DrainRate 三类反例；
- `dischargeSessionSegmentsByExternalConnected` / `pausedChargingAloneYieldsNoDischargeSession` / `lastChargeRequiresPositiveGainAndDuration` / `chargeSessionAveragesOnlyPositiveBatteryPower`：时段模型四例；
- `migratedV2LinesKeepUnknownPowerSource`：journal 中 v2 行按 unknown 处理；
- `remoteJSONLegacyFieldsDeriveSemanticsConservatively` 等：远端旧格式保守推导；
- 既有 journal 追加/坏行恢复/dirty 同步/24h+1500 上限/延迟 compact 测试全部保留并通过。

## 六、本地验证（CLT）

- 非视图层 + 全部测试合成单模块 `swiftc -typecheck -swift-version 6` → 0 error；
- 全部改动 Swift 文件 `swiftc -parse` 通过；
- 视图层完整类型检查受 CLT 缺 SwiftUIMacros 限制，由 CI 证明（既有环境约束）。

## 七、Instruments 证据方案与环境约束

- 本机仅有 CLT：无 xctrace/Instruments；`AXIsProcessTrusted()=false`，
  无法外部注入点击/滚动事件。
- 方案：应用内置休眠式采样钩子（`ProfileSupport`：UserDefaults
  「BatteryBarProfileAutoScroll」「BatteryBarProfileSection」门控的线性动画滚动 +
  初始页指定；默认关闭、零常驻开销），配合新增 `.github/workflows/ui-profile.yml`：
  在 Xcode runner 上构建安装、注入确定性种子数据（复刻真实污染形态 + 正常形态，
  见 `scripts/seed_profile_data.py`），对概览页与功耗页各录制
  SwiftUI（视图 body 求值）与 Animation Hitches 两份 trace：
  时间线 = 启动静止窗（~12s，验证每秒采样不重建根视图/Chart）→ 连续滚动 ~50s。
  digest 由 `scripts/profile_digest.py` 导出（结论见 §十一，随 CI 完成补充）。

## 八、CI / 安装 / 运行时证据

- Build run（最终代码）：全绿 —— `Test run with 86 tests in 12 suites passed`
- UI Profile run：见 §十一（Instruments 取证，含迭代记录）
- Artifact sha256（Build run 32601875482，commit fc8af96）：
  - `Contents/MacOS/BatteryBar`: `1947634f783f456322e14680420384594b30ef58bea81d98afb0ab962240f68c`
  - `Contents/Resources/BatteryBarHelper`: `208a2eb48e8501df2d898995c88b3325973760b3d2ba93ebbc85349be11f356c`
- 安装前备份：
  - 数据：`~/Library/Application Support/BatteryBar-backup-e199e59`（复制，原数据未动）
  - 上一版 app：`~/.Trash/BatteryBar-d6ea815-*.app`
- 安装：ditto 至 `/Users/mio/Applications/BatteryBar.app`；
  `codesign --verify --deep --strict` 通过；安装后二进制哈希与 artifact 完全一致
- 运行时验证（安装后）：
  - 新快照携带 `externalConnected:true`（本机恰处满电接电未充电状态），遥测实测负载如实记录 ✓
  - 污染隔离生效：最近 6h 负载均值旧规则 4.22W(n=212) → 新规则(trustedSystemLoad) 5.95W(n=135)，
    77 个未知来源估算点被排除；数据本身未删改 ✓
  - 零 `powermetrics` 进程；BatteryBar 进程 CPU 0.0% ✓
  - journal 追加式写入保持：70s 观察窗 inode 不变、行数 +1 ✓

## 九、安全边界确认

- 不启用 WebDAV、不发真实同步请求（同步配置未开启）；
- 不启用/安装/卸载 Helper、不触发管理员授权、不删除系统 Helper；
- 不删除用户历史数据（污染点仅统计层隔离）；
- 不扩大视觉重做范围（本轮仅状态表达、错误摘要、失效边界与休眠式采样钩子）。

## 十、自审发现（可操作项）

| severity | 发现 | 处置 |
|----------|------|------|
| medium | 充电时段平均电池功率若不过滤暂停期样本，会被 ≈0W 稀释（测试先行暴露） | makeSummary 对充电时段仅取 isCharging 样本，配套断言 |
| low | onBatterySegments 尾部可能产生零长时段 | drainRate 内 segmentSnaps.count>=2 校验天然过滤 |
