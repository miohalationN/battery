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
run 32601875487。下表记录首次四份 trace 齐备的运行。

### 11.2 run 32614419174 结果（四份 trace 全部有效，首次齐备）

| trace | 模板 | schema 数 | gate | 体积 |
|-------|------|-----------|------|------|
| usage-hitches | Animation Hitches | 51 | 必需 ✓ | 186MB |
| power-hitches | Animation Hitches | 51 | 必需 ✓ | 131MB |
| usage-swiftui | SwiftUI | 25 | 尽力 ✓ | 117MB |
| power-swiftui | SwiftUI | 25 | 尽力 ✓ | 116MB |

录制时间线：启动静止观察窗 ~12s（每秒采样照常运行）→ 自动滚动 ~50s
（UserDefaults 门控钩子驱动线性动画连续滚动）。workflow 结论 success 且
gate 为真实校验（红色必然代表必需取证不可读）。Build workflow 对同提交全绿。

### 11.3 最终 Instruments GUI 判读（run 32618151756）

- commit `9a980cc` 的 UI Profile run `32618151756` 与 Build run `32618151748`
  均成功；两页仍实际选择 Animation Hitches，required gate 各 51 schema。
- 新增 `scripts/capture_trace_review.sh`，由完整 Xcode runner 打开两份 trace，
  每页在 15/30/45 秒保存 1024×768 Instruments 截图。
  [artifact 9487986440](https://github.com/miohalationN/battery/actions/runs/32618151756/artifacts/9487986440)
  （zip SHA-256 `291fb609a7565fd238fb4d4aef22d6e3b7952d6c0c6efabd38760bfa54ce087c`）
  同时归档四份 trace、digest 与六张截图，保留 14 天。
- assurance agent 下载 artifact 后人工判读：usage 15 秒图无遮挡，已选中
  `Summary: Hitches`，完整 1:05 时间范围明确显示 `No Data / Nothing to Display`；
  power 三张图叠有 runner 的屏幕录制隐私提示，但其后方同一 Hitches 面板同样
  清晰显示 `No Data / Nothing to Display`。
- 原始 trace 的 indexed-store descriptor 交叉验证：两页 `hitches`、
  `hitches-frame-lifetimes/framewait/gpu/renders/updates` 的 `next_event_id` 全部为 0。
  因此本次确定性滚动窗口中，两页均为 **0 个 Instruments 识别的 hitch**，
  最长 hitch 不适用。
- 边界：该结论证明本次 Xcode runner 录制没有达到 Apple Hitches 判定阈值的事件；
  它不提供逐帧 FPS 数值，也不等价于所有硬件、所有时刻都“跑满帧率”。

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
工作流与文档（.py/.sh/.yml/.md），app 源码无变化，无需重装。最终视觉取证提交
`9a980cc` 的 Build run 32618151748 也全绿。

## 十、自审发现（可操作项）

| severity | 发现 | 处置 |
|----------|------|------|
| medium | 充电时段平均电池功率若不过滤暂停期样本，会被 ≈0W 稀释（测试先行暴露） | makeSummary 对充电时段仅取 isCharging 样本，配套断言 |
| low | onBatterySegments 尾部可能产生零长时段 | drainRate 内 segmentSnaps.count>=2 校验天然过滤 |

## 十一、1.1.0 品牌、同步与图表体验增量（2026-08-23）

### 11.1 品牌与兼容边界

- 基线 `5735451`，功能实现提交 `8456772`。用户可见名称统一为「电池监测」，副标题为
  「电池与功耗记录」，版本升至 1.1.0（build 2）。菜单栏、侧栏、弹窗、Helper 授权文案
  与应用元数据均使用新名称。
- 为确保无感升级，内部 executable/target、bundle id `com.batterybar.app`、数据目录、
  UserDefaults、Keychain、Helper/XPC 标识、WebDAV 远端路径及 GitHub artifact 名仍保留
  `BatteryBar`。本次不迁移、不复制用户数据，也不要求重新授权。

### 11.2 同步正确性与安全边界

- `SyncEngine.applySchedule(config:)` 成为定时器唯一 owner：每次配置变化先撤销旧定时器；
  禁用或手动模式不留后台 timer，启动与设置页修改立即应用。`lastSyncAt` 仅在真实同步成功
  后更新，配置错误、禁用、并发跳过和网络失败均不会显示伪成功。
- WebDAV 边界统一校验：只允许 HTTPS；HTTP 仅允许 localhost/127.0.0.1/::1。
  Basic Auth 重定向只允许同 scheme、host、有效端口，拒绝降级和跨源凭据泄漏。
- 回归覆盖 HTTPS/本机 HTTP/局域网明文/无 scheme、同源/跨源/降级重定向、调度状态转换
  与禁用同步时间戳。未启用用户 WebDAV，未发起真实同步请求。

### 11.3 图表与页面信息架构

- 功耗曲线使用所选时段的固定墙钟域，不再让少量样本横向铺满 6/24 小时；默认 1 小时，
  同时显示有效样本数和实际覆盖时长，避免用户把数据缺口误判为连续趋势。
- 同步页新增「本机数据」摘要（历史点、可用离电记录、24 小时保留）；「采样间隔」明确为
  「界面刷新间隔」，并说明历史仍每分钟写入。空态高度、卡片描边和弱文字对比度收紧，
  9pt 辅助文字提升至 10pt；未新增常驻模糊、阴影或动画。
- 本机对总览、功耗与同步三页做了运行态视觉检查：品牌层级、1 小时曲线口径、覆盖信息和
  本机数据卡均正确；稳定状态 CPU 0.0%，无 `powermetrics` 进程。

### 11.4 Gate、安装与限制

- GitHub Build run [32621672266](https://github.com/miohalationN/battery/actions/runs/32621672266)
  success：90 tests / 12 suites passed；package 与 artifact 上传均成功。本地 Swift parse、
  非视图层 Swift 6 typecheck、测试 typecheck、shell `bash -n`、`git diff --check` 通过。
  本机 CLT 缺 SwiftUIMacros，完整 SwiftUI 编译由 GitHub Xcode runner 证明。
- 同提交 UI Profile run [32621672275](https://github.com/miohalationN/battery/actions/runs/32621672275)
  success：总览/功耗均使用 `Animation Hitches` 模板，required trace 各 51 schema；两份
  SwiftUI trace 各 25 schema，截图、digest 与四份 trace 已上传 artifact `9488955963`
  （14 天保留）。该 gate 证明产物可读且模板正确；是否存在 hitch 仍以归档 GUI/descriptor
  判读为准，不用 schema 数冒充帧率结论。
- 已从 Build run `32621672266` 的 artifact 安装 `/Users/mio/Applications/BatteryBar.app`；显示名「电池监测」，
  版本 1.1.0 (2)，`codesign --verify --deep --strict` 通过。安装主二进制 SHA-256
  `cfd749b8ad159882dfb06038e1da6cf57cdc8030fe5cf849de3cdb03829e0760`，Helper
  `69a6ccc23de033668df2b4be948e0d3f9e7562353935662845e3370469b7029d`；旧 app 已可恢复地
  移至 `/Users/mio/.Trash/BatteryBar-pre-8456772-20260823-140010.app`，用户数据未触碰。
- 未安装、启用或卸载 Helper，未触发管理员授权，未触碰其他生产/外部系统。限制：内部
  `BatteryBar` 标识为兼容性设计，并非遗漏；尚未做公开发行所需 Developer ID/公证；
  性能取证只能证明指定 runner/滚动窗口，不承诺所有硬件始终满帧。

## 十二、1.2.0 采集层与高级采样专项（2026-08-23）

### 12.1 电池传感器与口径

- 基线 `01cc139`，功能提交 `f122000`。`BatteryReader` 新增
  `AppleSmartBatteryPack/BatteryData` 回退，修复新系统顶层无 `Temperature` 时温度恒为
  「—」；温度按百分之一摄氏度归一化并限制在合理设备范围。电压、电流、容量、循环次数
  同步增加有限值、范围与 UInt64 回绕哨兵过滤，多个候选逐项验证，坏的高优先级值不会
  阻断后续有效回退。
- 电池功率优先使用 `PowerTelemetryData/BatteryData.BatteryPower` 的控制器直读 mW，
  电压×瞬时电流仅作最终兜底；`PowerTelemetryData` 已知字段固定按 mW 换算，低于 250mW
  不再被启发式误判成数百瓦。系统负载、电池包功率和适配器输入功率保持三条独立通路。
- IOPS 读取失败改为可失败结果；UI 保留最后可信状态，存储跳过该分钟，不再合成 0%/离电
  污染快照和插拔状态机。健康度读取失败返回不可用而非伪造 100%；适配器输入功率改为
  独立高频字段，诊断页不再冻结在首次样本。

### 12.2 分项功耗采样

- Helper 协议升至 4.2，显式返回 `available/sampleTime`，合法 0W 不再等同采样失败；
  App 端对 XPC 数值再次做有限值/范围校验。`powermetrics` 强制 C locale 与行缓冲，
  mW/uW/W 解析抽到双方共用、可单测的 `TelemetryCore`。
- 界面将 CPU/GPU 从「实测」更正为 Apple 定义的模型估算；只有新鲜且系统负载为实测时
  才计算相对占比。高级功能更名「分项功耗采样」，明确默认关闭、10s 模型估算、不可跨
  机型比较。应用升级发现旧 Helper 时只标记需更新并关闭运行态开关，不会在启动时突然
  弹管理员密码；仅用户再次主动开启才安装。

### 12.3 证据、安装与边界

- GitHub Build run [32624069980](https://github.com/miohalationN/battery/actions/runs/32624069980)
  success：98 tests / 13 suites passed；新增温度、低 mW、异常电气值、XPC 边界和
  powermetrics 解析反例。本地非视图 Swift 6 typecheck、全部测试 typecheck、全源 parse、
  Helper build、shell 语法与 diff check 通过。
- 同提交 UI Profile run [32624069970](https://github.com/miohalationN/battery/actions/runs/32624069970)
  success：总览/功耗必需 Animation Hitches trace 各 51 schema，两份 SwiftUI trace 各
  25 schema；截图、digest 与四份 trace 归档在 artifact `9489532099`（14 天保留）。
- 实机只读探针：100%、接电未充电、温度约 41.9°C、约 12.8V，系统负载/电池功率/
  适配器输入分离，容量 4223/4382mAh、139 次循环。安装后 UI 总览显示温度 42.2°C，
  电源诊断同步显示电压、温度、适配器输入 3.4W、额定 15W、USB-PD；Helper 开关保持关闭。
- 已安装 GitHub artifact 至 `/Users/mio/Applications/BatteryBar.app`，版本 1.2.0 (3)，
  主二进制 SHA-256 `72e6bff020ebc35e6587b472478c0d0194851a9b6f9d76c9fab423673b462ddc`，
  bundled Helper `3791e8771973d080407a44a86a285424905c0af287e94447d76108f70cf745e1`；
  旧 app 可恢复地移至 `/Users/mio/.Trash/BatteryBar-pre-f122000-20260823-145434.app`。
- 未启用、更新、卸载系统 Helper，未触发管理员授权，未运行 `powermetrics`，未发起 WebDAV
  请求或修改用户数据。限制：IORegistry/powermetrics 字段随系统和机型变化，所有不可用
  情况选择显示「—」/缺口而非伪造值；分项功率是模型估算，不是精密功率计。

## 十三、1.3.0 前后台采样节奏专项（2026-08-23）

### 13.1 基础读数生命周期

- 基线 `860cbab`，实现提交 `2d8fa62`，测试夹具修复 `f6fefac`。主窗口与菜单栏弹窗分别
  登记可见需求：任一界面打开时立即读取一次，随后按用户设置的 1–30 秒轮询；两个界面
  都关闭后固定为 15 秒低频轮询并提供 2 秒 timer leeway。重复生命周期事件幂等，关闭
  一个界面不会把仍可见的另一个误降频；每分钟历史落盘保持独立。
- 设置项从易误解的「界面刷新」明确为「前台轮询」；页面展示当前模式、历史/分项节奏与
  「上次成功读取」秒级心跳。心跳隔离在小视图内，不带设置表单每秒重建。状态栏通知只在
  电量或充电态真正变化时发送，不再随相同值的每个 tick 广播。
- 实机每秒直接读 IORegistry 并施加 CPU 负载：`SystemLoad`/温度连续约 10 秒维持
  `6279mW/37.50°C`，随后一起更新为 `14575mW/37.79°C`。因此 1 秒是读取尝试频率，
  不能迫使驱动每秒产出；其价值是把驱动新值出现后的额外显示延迟压到约 1 秒以内。

### 13.2 高级分项采样

- CPU/GPU 分项从基础 UI timer 拆为独立 10 秒 timer，与 Helper 的 `powermetrics -i 10000`
  对齐；用户主动开启后才持续运行并服务实时读数与分钟历史，默认关闭时零 powermetrics。
  慢 XPC 仍禁止重叠。Helper 失败或样本超过 30 秒时，分钟快照写明确缺口（0），不再把旧
  分项值无限复制成看似连续的历史。界面同步说明开启高级采样会在后台持续运行。

### 13.3 Gate、安装与限制

- GitHub Build run [32625961800](https://github.com/miohalationN/battery/actions/runs/32625961800)
  success：103 tests / 14 suites passed，release App+Helper、完整 SwiftUI 编译、package 与
  artifact 上传全部成功。首轮 `32625876817` 的 App 编译已成功，测试失败仅因 Swift
  Testing 宏不能直接包裹 mutating 调用；修复夹具后全量重跑。新增反例覆盖前后台策略、
  双界面关闭次序、重复事件幂等、边界持久化与高级/历史独立节奏。
- 本地全源 parse、非视图 Swift 6 typecheck、Helper build、shell `bash -n` 与 diff check
  通过。安装后 5 秒 `sample` 中主线程 3766/3787（99.45%）样本在 `mach_msg` 等待，
  约 0.55% 落在 1 秒基础读取，无 SwiftUI body/layout/Chart 栈；稳定 `ps` CPU 0.0%。
- 已安装对应 artifact 至 `/Users/mio/Applications/BatteryBar.app`，版本 1.3.0 (4)，
  `codesign --verify --deep --strict` 通过。主二进制 SHA-256
  `d6793c78c8d7d1d6270dcb3b9681fe9ae8dc8a50e0500e52a54894dd8d14c84e`，bundled Helper
  `6ba5636413239f8ecce1c1757fa42291fc04bda27a8c272d1b8565996071f025`；旧 1.2.0 可恢复地
  位于 `/Users/mio/.Trash/BatteryBar-1.2.0-pre-1.3.0.app`。journal 在一分钟窗口 inode
  `21822045` 不变、行数 132→133，确认继续纯追加。
- 未启用/安装/卸载系统 Helper，UserDefaults 开关为 false，无 powermetrics 进程；未发起
  WebDAV 请求或修改历史内容。限制：锁屏导致本轮无法做最终 UI 点击/截图验收；GitHub 已
  证明视图完整编译，运行进程与数据通路正常。不同机型/系统的底层出数周期仍可能不同，
  应用只显示驱动真实发布值，不插值、不制造“每秒新数据”。

## 十四、1.4.0 数据、安全与资源专项（2026-08-24）

### 14.1 采集、数据解释与资源边界

- 基线 `e3410a9`；主体实现 `a8a9afe`，链接/签名修复 `04b0663`、`e332ede`，遗留 Helper
  只读提示补丁 `2d3e87c`。每轮基础读取合并为一个 `BatteryReading`，同一份 IOPS 状态与
  IORegistry 电池数据共同消费；三个大型嵌套字典每轮各复制一次，消除重复跨 IOKit 分配和
  插拔边界前后两次读数不一致。启动健康度优先用控制器容量，仅缺失时才后台运行
  `system_profiler`。
- 温度继续从 SmartBattery/Pack 多源归一化并已在总览、弹窗、功耗诊断显示；分钟快照 v4
  新增低电量模式与系统热压力，旧 v1–v3 仍无损兼容。显示器估算在屏幕关闭、亮度接口失败
  或越界时明确不可用（写 0），不再默认伪造 70% 亮度。关闭高级采样或 sampler 后，迟到
  XPC 结果不会重新污染已清零状态。
- 离电长期趋势最多绘制 240 个保极值点，完整样本仍用于统计；运行时 App 图标只解码 256px
  缩略图，Finder/Dock 继续使用完整 ICNS。实机完整窗口 footprint 约 47MB（上一版同口径曾
  约 80–81MB），RSS 稳定约 19MB；10 秒 sample 主线程 8561/8571（99.88%）处于
  `mach_msg` 等待，无持续 body/layout/Chart 栈，CPU 0.0%。`leaks` 为 19.8KB 系统框架级
  小对象，与此前基线相同量级。

### 14.2 WebDAV 与凭据安全

- 同步下载/目录列表使用临时文件后限长读取，压缩数据另设 6MiB 解压上限；设备、文件、
  快照和离电记录均有硬上限。畸形 XML/JSON、非 404 下载错误、目录列举失败一律使本轮失败，
  不会把“读失败”当远端空文件并上传覆盖；404 仍允许首次上传。同步成功返回前，dirty 清除
  与远端合并已同步落盘。
- 离电记录改为每设备独立文件，旧共享文件只读，消除多设备最后写入覆盖。Keychain 身份从
  单用户名改为规范化 origin+用户名，更新使用 `SecItemUpdate`，旧凭据只允许设置页首次载入
  既有配置时一次性迁移，不会随服务器地址变化带到另一源站。设备目录改用应用随机 UUID；
  旧硬件 Platform UUID 自动轮换但旧目录仍可下载。

### 14.3 Helper 提权边界

- Helper 5.0 同时校验调用方 bundle id 与安装时绑定的主程序 CDHash；Release 完全移除
  `BATTERYBAR_HELPER_PATH` 覆盖。安装 payload 必须位于已严格验签 App Resources 内，解析
  符号链接后仍在该目录；AppleScript 只通过 argv 和 `quoted form of` 传值，launchd plist
  由提权 shell 直接写最终路径，消除命令注入与临时 plist TOCTOU。
- 新 launchd job 只有 MachServices，不含 RunAtLoad/KeepAlive；powermetrics 空闲 60 秒停止，
  Helper 自身空闲 120 秒退出并由下次 XPC 按需拉起。关闭高级采样时仅比较系统/内嵌 Helper
  的签名 CDHash 来显示过期提示，不连接 XPC、不启动服务。
- 当前系统仍保留旧 4.2 Helper 与旧 KeepAlive job（PID 824，CPU 0.0%），本轮没有管理员授权，
  因而未擅自替换或卸载；高级采样开关保持 false、零 powermetrics。用户在功耗页再次主动
  开启并完成一次管理员授权后，才会安全替换为 5.0。这是当前唯一需用户参与的安全收尾。

### 14.4 Gate、安装与外部状态

- 最终代码 Build run [32679114508](https://github.com/miohalationN/battery/actions/runs/32679114508)
  success：114 tests / 16 suites，完整 SwiftUI 编译、Release App/Helper、严格签名、Release
  调试入口泄漏检查及 artifact 上传均通过。前一代码提交 UI Profile run
  [32628564782](https://github.com/miohalationN/battery/actions/runs/32628564782) success：两页
  Animation Hitches 各 51 schema、SwiftUI 各 25 schema；最终增量仅增加非视图磁盘签名比较。
- 已安装最终 GitHub artifact 至 `/Users/mio/Applications/BatteryBar.app`，版本 1.4.0 (5)；
  主二进制 SHA-256 `c51ab56bac8ac1036fd88704b34765d869ef6640859d33c6cf76b785587a4cc2`，
  bundled Helper `dbbe0e713317f1bdaa0da60632a70e16aa69589769030d848f26f556a1707763`，
  均与 artifact 一致且严格验签。原 1.3.0 位于
  `/Users/mio/.Trash/BatteryBar-pre-1.4.0-d6793c.app`；安装前数据备份位于
  `/Users/mio/Library/Application Support/BatteryBar-backup-pre-1.4.0-20260824`。
- 新快照实机写入 temperature 33.09°C、system load 13.715W、battery power 1.712W、
  externalConnected=true、lowPowerMode=false、thermal=正常；一分钟窗口 journal inode
  `21822045` 不变且行数 1185→1186，保持纯追加。未启用 WebDAV、未发真实同步请求、未修改
  历史内容；除 GitHub Actions、App 替换与上述可恢复备份外未触碰外部/生产系统。
