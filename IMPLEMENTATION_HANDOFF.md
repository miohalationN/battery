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
  digest 由 `scripts/profile_digest.py` 导出（结论见 §十一）。

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

## 十一、Instruments / 性能证据（最终 run 32614419174）

### 11.1 取证闭环修正（review 发现项）

前序 run 32603697964 存在三处取证流程缺陷，均已修复并有本地反例覆盖：
1. `.trace` 是目录包，旧脚本用 `-f` 判断导致成功产物被误判失败 → 改为 `-e`
   + 实际执行 `xctrace export --toc` 且输出含 ≥1 个 schema 才接受；
2. 三次失败后固定 `return 0` → 必需取证（两页 hitches）三次重试后非零退出；
   swiftui trace 保持尽力语义并显式告警；`rm` 目标限定 /tmp 白名单精确文件名，
   白名单外路径拒绝清理（exit 2）；main 置于 BASH_SOURCE guard 下可被测试
   harness source——stub xcrun 反例 7/7 通过（坏目录拒绝/好目录接受/白名单
   拒绝/三次失败非零且产物清理/成功接受/尽力容忍）。
3. workflow 曾用 `|| true` 吞掉 digest 错误、绿色≠有效 gate → 新增显式
   "Gate required traces" 步骤（存在性 + toc + schema 计数），digest 去除
   `|| true`（缺失→SKIP 退出 0；存在但损坏→非零），artifact 上传改 `if: always()`。
4. （P2，复审发现）Hitches 模板候选末位曾回退 Time Profiler——通用采样 trace
   不含 hitch/FPS 表却能通过"任意 schema"校验，冒充必需取证 → 已从 Hitches 候选
   移除该回退（仅 Animation Hitches/Hitches/Core Animation FPS）；反例覆盖：
   仅提供 Time Profiler 时 Hitches 模板必须为空、必需录制必须非零退出，
   SwiftUI 尽力语义保留其回退（harness 扩至 10/10）。

**更正**：早先报告把「power-hitches 51 schema」归到 run 32603697964 是错误的——
该轮两个 power trace 均损坏（schemas=0）；51 schema 的 power-hitches 来自更早的
run 32601875487。下表以最终 run 为准。

### 11.2 最终 run 32614419174 结果（四份 trace 全部有效，首次齐备）

| trace | 模板 | schema 数 | gate | 体积 |
|-------|------|-----------|------|------|
| usage-hitches | Animation Hitches | 51 | 必需 ✓ | 186MB |
| power-hitches | Animation Hitches | 51 | 必需 ✓ | 131MB |
| usage-swiftui | SwiftUI | 25 | 尽力 ✓ | 117MB |
| power-swiftui | SwiftUI | 25 | 尽力 ✓ | 116MB |

录制时间线：启动静止观察窗 ~12s（每秒采样照常运行）→ 自动滚动 ~50s
（UserDefaults 门控钩子驱动线性动画连续滚动）。workflow 结论 success 且
gate 为真实校验（红色必然代表必需取证不可读）。Build workflow 对同提交全绿。

### 11.3 工具链限制与需用户明确接受的项

- **行级指标需人工判读**：`xctrace export --xpath` 在 Xcode 26.6 工具链上对全部
  目标表（swiftui-updates、hitches* 等，已试 5 种 xpath 变体）只返回表 schema
  定义、不返回行数据。因此可见 hitch 数量/最长 hitch 时长无法在 CLI 量化，
  **本执行方也无可用的 Instruments.app**（本机仅有 CLT，无 Xcode/Instruments），
  无法完成人工打开 trace 的第 6 项要求——请用户在装有 Xcode 的机器上打开
  artifact 中归档的四份 trace 判读 hitch 数值，此项作为需用户明确接受的限制保留。
- 因此**不得宣称"零 hitch"或"跑满帧率"**；CLI 仅证明 trace 可读且结构完整
  （schema 齐备），hitch 行提取数为 0 属导出能力限制而非测量结论。

### 11.4 本机统计性证据（真实硬件、已安装 release 构建）

- `/usr/bin/sample` 10s / 7610 采样：主线程 7599/7610（99.87%）阻塞在
  `mach_msg_trap`（RunLoop 事件等待），仅 11 个采样（0.14%）位于 Swift 并发
  任务完成例程（每秒采样 tick）；10 秒内主线程无任何 SwiftUI body 求值 /
  视图布局 / Chart 渲染栈。
- 对照校准：历史上 objectWillChange 每秒风暴 + 全树重建时代同类测量约 40% CPU
  （MAINTENANCE_PLAN T-29/T-30）——若每秒采样仍重建页面根或历史 Chart，必然
  留下周期性 body/layout 栈与高 CPU；实测为零。
- 配合 ps 实测 CPU 0.0% 与根视图仅读低频属性的代码结构，
  构成"每秒采样不重建页面根/历史 Chart"的证据链。

### 11.5 已安装二进制一致性

安装产物取自 Build run 32601875482（commit fc8af96）；其后提交仅涉及采样脚本、
工作流与文档（.py/.sh/.yml/.md），app 源码无变化，无需重装。

## 十、自审发现（可操作项）

| severity | 发现 | 处置 |
|----------|------|------|
| medium | 充电时段平均电池功率若不过滤暂停期样本，会被 ≈0W 稀释（测试先行暴露） | makeSummary 对充电时段仅取 isCharging 样本，配套断言 |
| low | onBatterySegments 尾部可能产生零长时段 | drainRate 内 segmentSnaps.count>=2 校验天然过滤 |
