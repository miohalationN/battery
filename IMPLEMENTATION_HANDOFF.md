# IMPLEMENTATION_HANDOFF — 事件驱动采样、质量模型、分钟聚合、可信估算 与 assurance 返工

> 执行 Agent 移交文档，供 assurance/review agent 独立验证。
> 上一轮功能基线：`664c9fe`（A=`2d386b4`、B=`43bb2eb`、修复=`e3997af`，最终 `3782360`）。
> 本轮 assurance 返工基线：`37823602905a70e83321a93878d7074bb628373b`（clean 且与 origin 同步）。
> 返工提交链：主体 `7856729` → `4e82875`（LoginItemState 补 openApprovalSettings 转发）
> → `765c2e2`（矛盾用例窗口修正）→ `bbf7014`（用例自诊断化）→ `103b333`
> （根因修复：矛盾用例补容量/电压输入；LoginItemState 初始刷新真实状态）。
> 最终功能源码 HEAD=`103b333`；此后仅文档提交。不 force push，未改写任何已有提交。

---

## 〇、本轮 assurance 返工交付摘要

### 目标一：电池功率可用性与方向（冻结）

- `BatteryInfo` 新增 `batteryPowerAvailable`：区分「可信的有效 0W」与「没有读到功率」。
  遥测节点原始值恰为 0 → 可信零瓦（available=true, value=0）；归一化越界坏数据 → 不可用；
  电压×电流兜底仅在乘积 >0 时可用。兼容哨兵 0 只留在 BatterySnapshot 兼容字段，
  不进入质量模型（`batteryPowerMetric`：可信零瓦 = available+some(0)，不可读 = unavailable+nil）
  与分钟积分。
- `BatteryReading.batteryChannel` 冻结规则：① 接电+充电+功率可用 → charge；
  ② 明确离电+未充电+功率可用 → discharge；③ 接电未充电 / 矛盾状态（离电却在充电）/
  来源未知 / 功率不可用 → unknown；④ unknown 不累计任何一侧 seconds/Wh。
- **旧数据限制（明确记录）**：e3997af 期间按旧规则把「接电未充电」也计入
  batteryChargeWh，这些历史值不适合作为将来可信充电能量来源；本修复不做无法
  可靠推导的迁移，仅从新快照起按冻结规则记账。用户历史与 journal 未被删除或改写。
- 反例：BatteryChannelTests（六种状态映射）、聚合器 unknown 零累计（Wh 与 seconds
  双零）、有效 0W 放电计覆盖 Wh=0、质量模型 trustedZero vs sentinel。

### 目标二：估算展示门槛（强制执行）

- `RuntimeEstimator.dischargeEstimate` 单路/融合出口与 `chargeEstimate` 出口统一经
  `gated()`：最终 confidence < 0.40 一律返回 nil；内部证据可低置信存在
  （`historicalSlopeEvidence`/`batteryPowerEvidence` 不降级）。
- 测试修正：20 分钟降 2%（conf≈0.333）证据成立但 dischargeEstimate nil；
  充电 5 分钟 +1%（conf≈0.15）nil；涓流（0.54→0.324）nil；200%/h 拒绝。
  新增高置信矛盾用例（60 分钟降 5% 斜率 conf=1 + 功率 50%/h conf=0.66 →
  融合 conf≈0.498 ≥0.4 可展示、failureReason 标注差异、区间扩大）；
  低置信矛盾（≈0.298）→ nil。

### 目标三：分钟聚合与范围覆盖率（修正）

- `maximumThermalState` 每自然分钟重置（`beginWindow` 清零）；持续热状态由新分钟
  首次 setState/observe 重新登记。反例：第一分钟严重、第二分钟正常不继承。
- `BatterySnapshot.apply`：temperatureCoverage<0.5 仅置 temperatureAverage=nil，
  该分钟确实观察到温度时 maximum 保留并附覆盖率（反例 cov=0.3/max=40）。
- 新增纯函数 `RangeStatistics`（无 SwiftUI 依赖）：总覆盖率分母 = 所选范围墙钟时长，
  完全缺失的分钟计未覆盖，按 aggregateWindowStart 去重并限窗，coverage 裁 0...1；
  能耗仅累加覆盖达标（≥0.8）的 systemEnergyWh。反例：6 小时 1 完整分钟 ≈1/360、
  1 小时 60 完整分钟 =100%、中间缺口降低覆盖率、窗口外/重复窗口排除。
  PowerTab 改用该纯函数。

### 目标四：质量与同步安全边界

- `readAt` 在 IOPS+IORegistry 本轮读取全部完成后取得，文案仍解释为 App 完成读取时间。
- `PowerSampler.stop()` 先关闭 `isStarted` 门控再撤销各事件源/定时器/迟到 Task；
  `sampleUI`/`sampleStorage`/`fireStorage` 统一阻止 stop 后写状态或 journal。
- `BatterySnapshot.from(remoteJSON:)` 对 v5 可选字段保守校验：
  coverage/fraction/brightness 限 0...1；功率 0...500、能量 0...20、温度 -20...100、
  时间戳 0...2100 年，全部要求 finite；thermalPeak 白名单（正常/偏高/较高/严重/未知）
  且 ≤16 字符；sysCov<0.8 清除 sysEWh/sysPAvg/sysPPeak；tCov<0.5 清 tAvg 但保留合法
  tMax；无合法 aggWin 时清空全部聚合字段。畸形可选字段降级为 nil，不因一个附加字段
  破坏整条旧格式兼容记录。反例：巨大数值/负能量/越界覆盖率/门控不一致/无 aggWin/
  非法 thermal 标签/合法 v5 行不受影响。

### 增量一：电池健康口径

- 首选 macOS system_profiler 报告值（本机 98%），不再因 IORegistry 容量比 >0 而跳过；
  容量比（FCC÷DC，本机 96.3%）仅作回退并标注「容量比估算（非系统健康度）」；
  全部缺失显示不可用，不默认 100；不使用 StateOfCharge。
- 后台低频：启动一次 + 小时级 TTL（`BatteryHealthMetric.shouldRefresh` 纯函数）+ 唤醒后；
  60 秒进程内缓存防重复 spawn；绝不进入 5/15 秒采样路径，不阻塞主线程。
- Popover 与主窗口消费同一 `healthMetric` 模型，带来源/读取时间/估算标注。
- 反例：fixture "98%" 解析、系统值优先于容量比、回退标估算、全缺不可用、TTL 节流。

### 增量二：开机自启动入口

- `LoginItemState`（@MainActor @Observable）+ `LoginItemControlling` 可注入协议 +
  `SystemLoginItemController` 包装 SMAppService；init 即读取系统真实状态。
- 右键菜单与「数据与设置」页「应用设置」卡片 Toggle 共用同一实例，禁止两套逻辑漂移；
  requiresApproval 不假装已开启并显示「需要在系统设置中允许」+ 打开系统设置按钮；
  register/unregister 失败刷新真实状态并返回可理解错误；onAppear/应用激活刷新。
- 反例：开启/关闭/需批准/注册失败/注销失败/refresh 感知外部改动（LoginItemStateTests，
  stub 注入）。

### 增量三：采样文案

- 移除 Popover 顶部「5 秒兜底轮询/15 秒保活轮询」徽标；底层 5/15/60/10 策略不变。
- 「自动采样」主卡改为用户语言（界面打开提高频率/后台降低占用、功率温度取决于
  macOS 驱动、历史每分钟记录）；精确秒数与最近读取时间收进默认折叠的「采样诊断」
  DisclosureGroup（PollingHeartbeat 独立小视图，不引发整页周期重绘）。
- 页面标题改为「数据与设置」。

---

## 一、交付范围与角色边界遵守情况（沿用）

算法/口径/不变量按任务书冻结实现，未改成普通算术平均、瞬时值×整段时间、缺口插值
或固定机型经验值。IORegistry 无硬件时间戳的字段一律保持 nil（`sourceSampleAt`
在质量模型层面仅 powermetrics 来源允许非 nil，其余来源强制 nil）。

## 二、删除伪“刷新频率”功能（提交 A）

- 设置页 1–30 秒步进器与 `RefreshIntervalChanged` 运行时链路整体移除；
  `DataStore` 不再有 `currentRefreshInterval` / `updateRefreshInterval` /
  `refreshIntervalFile`（源码级反例测试 `userRefreshIntervalControlIsRemovedFromSource`
  防回归）。旧 `refresh-interval.json` 保留在用户目录但被忽略，未删除。
- 固定策略（`SamplingCadence`）：读数界面可见每 5 秒兜底；不可见每 15 秒；
  界面打开立即读取（`setReadingSurface`）；历史每 60 秒落盘；
  Helper/powermetrics 独立 10 秒。
- 事件驱动：IOPS 电源变化用 `IOPSNotificationCreateRunLoopSource`（C 函数指针回调经
  弱引用 context 桥回 MainActor，source 只挂主 RunLoop，注销同步完成）；低电量模式
  `.NSProcessInfoPowerStateDidChange` 与热压力 `ProcessInfo.thermalStateDidChangeNotification`
  立即更新。通知风暴由 `NotificationCoalescer`（纯逻辑、时间注入）按 ~180ms 合并：
  窗口内事件合并为一次延迟触发；stop 后事件回调不得写状态（`isStarted` 门控 +
  注销）；基础读取全部主线程同步执行，天然串行不重叠。
- IORegistry 功率/温度无可靠公开逐字段通知，保留 5/15 秒兜底；设置页改为只读
  “自动采样”说明（前台5秒/后台15秒/历史60秒/分项10秒 + 驱动发布延迟解释），
  Popover 徽标显示当前兜底节奏。

## 三、数据质量与来源模型（提交 A）

`TelemetrySample<Value>`（Sources/BatteryBar/Models/TelemetryQuality.swift）：
value 可选（`.some(0)` 合法）、availability、source/provenance、isEstimated、readAt
（App 完成读取时刻）、changedAt（首次观察到当前归一化值时刻）、sourceSampleAt、
stableFor（=「App 观察到数值持续未变」，文案明确不写“传感器未更新”）。

不变量：同值重复读取只推进 readAt；值变化（含 available↔unavailable 切换）推进
changedAt；sourceSampleAt 仅 `.powermetrics` 允许填写，其余来源强制 nil——
App 时间绝不冒充传感器采样时间。

来源枚举区分 IOPowerSources / PowerTelemetry.SystemLoad / BatteryData.SystemPower /
PowerTelemetry·BatteryData.BatteryPower / Voltage×CurrentDerived /
SmartBatteryTemperature / SmartBatteryPackTemperature / ProcessInfo / DisplayIOKit /
powermetrics / mixed(预留) / unavailable。BatteryReader 每轮返回 provenance +
readAt；功耗诊断区展示来源标签、可用性、实测/估算、“读取于 hh:mm:ss · 持续 Xs”。

## 四、显示器算法纠正（提交 A）

删除 `estimateDisplayPower` 的“1.5W+亮度×2.5W”瓦数模型；新快照不再制造显示器瓦数
（`displayPower` 恒 0，字段保留仅为 v1–v4 解码兼容）；组件构成不再显示伪瓦数，
改为亮度行“xx%”或“不可读取”（本机当前即不可读取，如实显示）。系统总负载本身已含
显示器影响，不再强行拆分。

## 五、分钟聚合器与 BatterySnapshot v5（提交 A）

`WindowTelemetryAggregator`（纯逻辑、时间显式注入、O(1) 内存：只留当前窗口 +
最近一个完成窗口）：

- 连续量零阶保持积分；单样本保持上限 = min(30s, 2×取得该样本时的预期间隔)
  （前台 5s→10s，后台 15s→30s）；超时部分为缺口严禁外推；乱序/负时间整条拒绝；
  睡眠开始 `truncateContinuity` 立即截断且 screenOn=false，睡前功率不延伸进睡眠窗口。
- 能量口径：仅 trustedSystemLoad 进 systemEnergyWh；systemPowerAverage=能量÷有效时长、
  peak=有效区间最大值、coverage=有效时长÷60s；接电充电功率只进 batteryChargeWh，
  batteryChargeWh/batteryDischargeWh 严格分开；有效零瓦计入覆盖，缺失不计；
  不按 coverage 反推能耗。
- 温度按时长加权平均（非样本算术平均）、独立最大值与覆盖率。
- screenOnFraction / lowPowerModeFraction 由通知切换时刻精确累计（只有 true 状态计入
  份额），maximumThermalState 取窗口内最高等级；不受 30 秒保持上限约束。
- v5 快照新增字段全部可选 encodeIfPresent/decodeIfPresent：aggregateWindowStart、
  systemEnergyWh/systemPowerAverage/systemPowerPeak/systemCoverage、batteryChargeWh/
  batteryDischargeWh、temperatureAverage/temperatureMaximum/temperatureCoverage、
  screenOnFraction/lowPowerModeFraction/maximumThermalState、displayBrightness/
  brightnessAvailable/brightnessReadAt。快照写入侧按冻结阈值门控：
  coverage≥0.8 才写能耗/均值/峰值；温度趋势 ≥0.5 才写均值/最大值（覆盖率始终如实记录）。
- WebDAV JSONL 同步新增 aggWin/sysEWh/sysPAvg/sysPPeak/sysCov/batChgWh/batDisWh/
  tAvg/tMax/tCov/screenFrac/lpmFrac/thermalPeak/bright/brightOK/brightAt 键；
  远端缺键保持 nil 不推导。v1–v4 本地解码、journal 与远端旧格式全部兼容；
  journal 保持追加式，未重写任何现有内容。

## 六、续航/充电估算重构（提交 B）

删除 DrainRateCalculator 全部 machineBaselineDrainRate、默认 11.1V、固定 6W/9W
机型表与“证据不足仍给数字”路径。新 `RuntimeEstimator`（纯逻辑、输入有界 ≤120
快照 + ≤120 分钟点）产出 `EstimationResult`：valueHours/rate/confidence(0...1，
映射 low<0.4≤medium<high≥0.7)、basis(systemReported/historicalSlope/batteryPower/fused)、
evidenceDuration/coverage、可选 lower/upperHours、failureReason。

- A 历史百分比斜率：仅明确离电且来源明确的最近 60 分钟；跨度 ≥20 分钟、净下降 ≥2%、
  覆盖率 ≥0.7（[t,t+65s) 并集/跨度）；间隔 ≥5 分钟点对 (levelStart-levelEnd)/hours，
  Theil–Sen 中位斜率；中位斜率 ≤0 不可用；confidence=min(跨度/60min, 净下降/5%, 覆盖)。
- B 电池功率证据：最近 15 分钟 batteryDischargeWh ÷ 有效时长（有效时长 <600s 视为
  证据不足）；fullEnergyWh 仅当 FullChargeCapacity 与合理电压均真实可用时
  capacityAh×voltageV（容量 1000–30000mAh、电压 8–20V 之外的坏数据直接拒绝不夹值）；
  powerRate=平均放电功率×100/fullEnergyWh；瞬时电压路径置信度上限 0.66。
- C 融合：两路有效按各自 confidence 加权速率；相差 >2× 总置信度 ×0.6 并扩大区间
  （failureReason 标注“两路证据差异较大”）；总置信度 <0.4 不显示 App 估算。
  remainingHours=currentLevel/fusedRate。IOPowerSources 系统剩余时间为独立
  systemReported 证据（confidence 0.3），永不静默混算；App 证据不足回退展示并标
  “系统估算”。明确接电或来源未知一律不显示离电续航。
- 充电估算：仅 isCharging 且接电；最近 30 分钟 Theil–Sen 正斜率（方向 -1 翻转上升序列）、
  跨度 ≥5min 且净增长 ≥1%；>80% 置信度 ×0.6；暂停/满电保持/无正增长不显示；
  斜率 >80%/h 直接拒绝（不再夹值）。UI 标注“按当前充电速度”。
- OffPowerRecordAnalyzer 保留原门槛，CycleTab 文案明确“按该离电时段速率折算，
  不是整机保证续航”。
- 重算触发：新分钟快照、电源状态切换、最多每 30 秒节流兜底；绝不每 5 秒扫描全量。

## 七、界面结果（提交 B）

- 功耗曲线优先 v5 `systemPowerAverage`（coverage≥0.8 成点，>90s 缺口断线，不插值）；
  新增电池温度趋势卡（`temperatureAverage`，tooltip 附窗口最大值与覆盖率）；
  无聚合点的旧范围回退瞬时 trustedSystemLoad 曲线（同一断线规则，240 点预算不变）。
- 新增所选范围能耗 Wh 统计：仅累加覆盖达标的 `systemEnergyWh`，同时显示总覆盖率。
- 续航结果必须带来源（系统估算/历史趋势/功率估算/融合）与置信度；不足显示
  “正在校准”。Popover headline 同口径。
- 失效边界保持：页面根只读低频状态；TrendChartPlot 为输入 Equatable 的隔离子树；
  未新增常驻 blur/阴影/根视图每秒刷新；趋势点硬上限 240。

## 八、测试反例清单（全部落地）

- 采样：固定 5/15 秒策略、双界面交错幂等、合并器 fireNow/delay/mergeIntoPending、
  holdLimit 冻结公式、源码级“无用户刷新间隔控制”反例。
- 质量：同值只变 readAt、变值推进 changedAt、available↔unavailable 推进 changedAt、
  IORegistry sourceSampleAt 强制 nil、powermetrics 保留真实硬件时间、合法 0 可区分。
- 聚合：10W 整分=1/6 Wh cov=1；前 30s@10W+后 30s@20W=0.25 Wh 均 15W；单样本仅保
  30s=0.083333 Wh cov=0.5 不外推；充电功率不进系统能耗；充/放分开且 unknown 排除；
  温度加权 30°C/最高 40°C；有效零瓦计覆盖缺失不计；乱序拒绝；睡眠立即截断；
  前后台节奏切换改变保持上限；低电量份额精确累计；跳缺分钟不生成空窗口且只保留
  最近完成窗口。
- 估算：20 分钟降 2% → Theil–Sen 6%/h 且 78%≈13h；单点回跳不毁中位斜率；
  跨度/下降/覆盖不足 nil；接电与未知源样本完全排除；5000mAh×12V=60Wh @6W→10%/h、
  50%≈5h；电压缺失/荒谬拒绝（绝不用 11.1V）；矛盾证据降置信扩区间；一致证据不误报；
  两路皆空返回 nil 但 systemReported 独立可用；接电/未知不显示离电续航；正常充电
  6%/h 折算充满时间；暂停/满电保持/无正增长不显示；涓流降置信；200%/h 异常直接拒绝。
- 兼容：v4 JSON 解码 v5 全 nil；v5 编解码往返；远端 v5 键往返 + 旧端缺键不推导；
  聚合写入覆盖率门控（<0.8 能量缺失、<0.5 温度趋势留空、覆盖率如实记录）。
- CI 实测：Build run 32683610847 —— **135 tests in 20 suites passed**。

## 九、本地验证（CLT-only 环境）

`scripts/local-gate.sh`（本轮新增并纳入仓库）：
1. 全源 `swiftc -parse`；
2. 非视图 Swift 源 + 全部测试剥除 import 后合成单模块 `-typecheck -swift-version 6`；
3. （本轮新增）同输入 `-O -whole-module-optimization -emit-object` 完整编译，
   与 CI Release 同口径触发 SIL 独占访问等 WMO 诊断；
4. Helper build（不安装、不触碰 launchd）；
5. `bash -n`、`git diff --check`。
视图层完整类型检查受 CLT 缺 SwiftUIMacros 限制由 CI 证明（既有环境约束）。

### CI 失败记录（透明披露）

- 提交 A（run 32682438143）：PowerTab 在 String 插值中使用 `(date, format:)` ——
  String 插值不支持该参数。修复为 `formatted(.dateTime...)`，随提交 B 推送。
- 提交 B（run 32683340063）：Release WMO 下聚合器 `consume(&stream)` 与 mutating
  接收者重叠访问。修复为 static 函数（`e3997af`），并把该诊断纳入本地门禁第 3 步。
- 最终代码 run 32683610847 全绿（build+签名检查+135 tests+artifact）。

## 十、GitHub artifact 与安装哈希

只从绿色 Build run 32683610847（HEAD=e3997af731ef0f67411fa3e3922676eb4b65715e）
下载 artifact `BatteryBar.zip`：

- `Contents/MacOS/BatteryBar` SHA-256 =
  `e2ec2a3e9bd0ea96132eb04016bde97c5f896b6a646c48cf1db16741f70c7a81`
- `Contents/Resources/BatteryBarHelper` SHA-256 =
  `0374c96d8afc65f31ba770aec08e80b25d2471ab1adc9dff825d69edefbc82ae`

`codesign --verify --deep --strict` 通过（app 与 helper 分别严格验签）；
`strings` 确认无 `BATTERYBAR_HELPER_PATH` 调试入口。安装后二进制哈希与 artifact
逐字节一致（见上）。

## 十一、备份、安装与运行时证据

- 安装前备份：
  - 数据：`~/Library/Application Support/BatteryBar-backup-pre-v5-20260824`
    （复制；原目录未被改动）
  - 上一版 app：`~/.Trash/BatteryBar-pre-v5-103915.app`（可恢复）
- 安装：ditto 至 `/Users/mio/Applications/BatteryBar.app` 后启动（pid 80720）。
- journal 一分钟窗口：inode `21822045` 不变，行数 1274→1277+（纯追加，未重写）；
  最新行含完整 v5 字段且语义正确：`externalConnected=true/isCharging=false`（满电保持）
  时 `batteryChargeWh=0.0246 / batteryDischargeWh=0` 方向分离正确；
  `systemCoverage=1` 时 `systemEnergyWh=0.2326`、加权 `temperatureAverage=38.93`、
  `temperatureMaximum=39.09`、`maximumThermalState=正常`、`screenOnFraction=1`；
  亮度接口不可读取时 `brightnessAvailable=false`、`displayPower=0`（不伪造）。
- 进程资源：App `%CPU=0.0`、RSS≈16.9MB；sample 显示主线程 2587 个样本处于
  `mach_msg` 事件等待；helper/powermetrics 无进程。
- 网络：进程无任何 TCP 连接；从未存在 sync-config.json（WebDAV 从未启用），
  无真实 WebDAV 请求。
- `refresh-interval.json` 原样保留（运行时不读取）。

## 十二、Helper 开关状态说明（重要，需用户知晓的一次性动作）

用户原开关状态：**开启**（`BatteryBarHelperEnabled=1`）。安装新构建后 App 启动时的
既有安全设计生效：Helper 5.0 在安装时绑定了旧版主程序 CDHash，而新构建的主程序
CDHash 不同，XPC 版本校验失败 → App 自动关闭运行态开关（UserDefaults 变 0）并提示
“Helper 需要更新”。这不是本次重构引入的行为变化，而是既有提权边界（§14.3 既有移交）
在新 App 二进制下的必然结果：

- 本次过程**没有**请求管理员密码、**没有**安装/卸载/修改系统 Helper 或 launchd、
  **没有**调用任何安装脚本；系统 Helper 二进制/plist 保持原状。
- 用户下次在功耗页主动开启“分项功耗采样”时会弹出一次管理员授权，安装与新 App
  CDHash 绑定的更新 Helper，此后开关恢复常开。此动作只能由用户完成。

## 十三、外部系统触碰状态

- WebDAV：未启用、无真实请求（配置文件不存在）。
- 系统 Helper/launchd：未安装/卸载/修改；仅 App 自身启动时做过一次常规 XPC 版本探测
  （随后按设计关闭运行态开关）。
- 管理员授权：全程未请求、未保存任何密码。
- 用户数据：journal 只追加未改写；refresh-interval.json / usage-state.json 原样；
  数据与旧版 App 均有可恢复备份（见 §十一）。
- git：普通 push 到 main，无 force push，无历史改写。

## 十四、UI Profile 取证（返工轮）

返工轮 run `32689383898`（commit 103b333）**success**：usage/power 两页的
Animation Hitches trace 与 SwiftUI trace 均一次录制即被接受（trace accepted），
「Gate required traces」校验非空通过。未以 schema 数宣称零 hitch，hitches 表
内容以 artifact 为准供独立复核。（上一轮 32683610852 的取证结论同样有效。）

## 十五、返工轮 CI 失败记录（透明披露）

- 7856729（主体）：SyncTab 调用 `loginItem.openApprovalSettings` 但模型未转发
  → 4e82875 补转发。
- 765c2e2：`highConfidenceContradictionStaysObservable` 在 CI 上返回单路
  historicalSlope——自诊断消息（#require 携带完整 Inputs 现场，15 个窗口
  1800002760…1800003600 全部在界内）定位到根因：该用例漏设
  `fullChargeCapacityMah`/`voltageMV`，功率证据被正确拒绝；另 `LoginItemState`
  init 未读取系统真实状态导致三项状态测试失败。103b333 一并修复。
- 最终代码 run `32689383815` 全绿：**167 tests / 26 suites passed**，完整
  SwiftUI build、Release App/Helper、严格签名检查、artifact 上传均通过。

## 十六、返工轮 artifact、安装与运行时证据

- 只从绿色 run 32689383815（HEAD=103b3333e5c438832aae6dcd4978efd766825344）下载：
  - `Contents/MacOS/BatteryBar` SHA-256 =
    `fdede122071ddc426130fdb165f2a84cc951e3dd91f5eebc8f72d91a5de9713c`
  - `Contents/Resources/BatteryBarHelper` SHA-256 =
    `e491185a5540798fd5d34c406ec4258f03e9c57c98e736aa67b75e72bea71e94`
  - `codesign --verify --deep --strict`（app/helper 分别）通过；无调试入口字符串。
- 安装前备份：数据 `~/Library/Application Support/BatteryBar-backup-pre-fix-20260824`；
  旧 App `~/.Trash/BatteryBar-pre-fix-*.app`。ditto 安装后哈希逐一比对一致。
- journal：inode `21822045` 不变，行数 1374→持续追加；最新行 v5 字段语义正确。
- 运行时边界：App CPU 0.0%、RSS≈14.9MB（启动瞬态后回落），零 TCP 连接，
  WebDAV 从未启用无请求；helper/powermetrics 无进程。
- 「接电未充电不累计充电能量」的运行期验证说明：本机自安装起持续处于**活跃充电**
  （isCharging=true，用户插电使用中），无法自然进入「接电未充电」观察窗口；
  活跃充电期 batteryChargeWh 正常累计（规则①正确方向），反向证明方向门控在
  实机生效。接电未充电→unknown→双侧零累计由本地可执行纯逻辑 harness（24 项
  反例全 PASS，含 unknown 零累计、有效 0W 计覆盖）与 CI 167 项测试
  （BatteryChannelTests / 聚合器 unknown seconds 双零）证明，不依赖等待系统
  状态变化。

## 十七、返工轮遗留限制

1. 历史 batteryChargeWh（e3997af 规则产物）不可作为可信充电能量来源，已声明
   （见§〇目标一），无迁移。
2. 系统 Helper 仍绑定旧 App CDHash：本返工轮未触碰 Helper/launchd，未请求
   管理员授权；用户下次主动开启分项采样时需一次授权更新（沿用§十二说明）。
3. 开机自启动 requiresApproval 路径需用户在系统设置手动允许，应用只能引导。

## 十八、外部系统触碰状态（返工轮）

- WebDAV：未启用、无真实请求。系统 Helper/launchd：未安装/卸载/修改。
- 管理员授权：全程未请求。用户数据：journal 只追加；备份完整可恢复。
- git：普通 push 至 main，无 force push，无历史改写；最终 HEAD 与 origin/main 同步。

`.github/workflows/ui-profile.yml` 对概览页与功耗页录制 SwiftUI 求值与 Animation
Hitches trace（本页图表改动后必须取得有效 hitches trace）。本轮 run
32683610852（commit e3997af）**success**：`usage-hitches.trace` 与
`power-hitches.trace` 一次录制即被接受（trace accepted），Gate required traces
步骤校验两份 hitches trace 的 schema 非空后通过；SwiftUI 求值 trace 同样各一份
有效。digest 与原始 trace 已上传为 artifact `ui-profile`（ID 9505291304）。
未以 schema 数宣称零 hitch，hitches 表内容以 artifact 为准供独立复核。


---

## 十九、第三轮 assurance 返工交付摘要（功能基线 103b333，HEAD 91aa14c）

本轮四项验收修复 + 实测验证，功能提交 `86b9c1d`：

### 目标一（P1）电池功率来源选择纯逻辑
- 新增 `Calc/BatteryPowerSelection.swift`：按既定优先级取「第一个存在且合法的
  直接值」；合法值含原始 0，0 立即胜出（available=true/value=0），禁止被低优先级
  节点或电压×电流乘积覆盖；缺失/越界坏值才允许继续；全部直接来源无合法值时，
  才允许乘积>0 的 V×I 回退（estimated）。`BatteryReader` 改为调用该纯函数，
  删除原内联 `sawZeroTelemetry` 逻辑（旧逻辑会让低优先级正值覆盖高优先级 0，
  与冻结规则冲突）。
- 反例（`BatteryPowerSelectionTests` 6 条）：高优先级 0 vs 低优先级正值→0；
  raw=0 vs V×I>0→0 且非 estimated；高优先级坏值→低优先级正值；全缺+V×I>0→
  乘积回退；全缺且乘积 0→unavailable；低优先级坏值不污染高优先级正值。

### 目标二（P2）远端 v5 aggWin 清洗修复
- 修复 `from(remoteJSON:)` 无合法 aggWin 后 tMax/tCov 被重新赋值的问题：
  `temperatureMaximum`/`temperatureCoverage` 改为 var，随其余聚合字段一并置 nil
  （原实现把 nil 清空又用局部常量覆盖回去）。
- 重写 `missingWindowClearsAllAggregateFields` 使用真实协议键
  `batDisWh`/`tMax`/`tCov`；新增 `illegalAggWinClearsAllAggregateFields` 覆盖
  越界数值（1e300）、非数值（字符串）、负值——均等价于缺失，全部聚合字段为 nil。
- 亮度点读数独立保留沿既有设计，不扩大范围。

### 目标三（P1）开机自启动 .notFound 不再视为永久不可用
- 实机确认 `SMAppService.mainApp.status == .notFound`（BTM record not found）。
- `LoginItemState.statusSubtitle` 的 .notFound 从「当前环境不可用」改为
  「关闭（尚未注册）」；SyncTab Toggle 移除 `.disabled(status == .notFound)`，
  首次无记录也可操作；用户开启调用 register，失败刷新真实状态并返回可理解错误。
- `SystemLoginItemController.openApprovalSettings()` 改用官方
  `SMAppService.openSystemSettingsLoginItems()`。
- 新增反例：.notFound→setEnabled(true) 成功转 enabled；.notFound 注册失败恢复
  真实状态；requiresApproval 语义不变；openApprovalSettings 转发。

### 目标四（P2）接电时段展示语义
- `currentCharge` 卡片改称「本次接电」（不再无条件称「本次充电」/「已充入」）。
- 新增纯函数 `UsageSessionModel.chargeDeltaDisplay(deltaPercent:)`：
  正增长→「电量增加 +N%」可高亮；零/负增长→中性「电量变化 0%/-N%」不绿不高亮。
- UsageTab 摘要行与图例按该模型渲染，100→97（ext=true）反例验证为「电量变化 -3%」，
  不出现「已充入 -N%」；lastCharge ≥1% 且 ≥5min 门槛不变。

## 二十、本轮验证

- 纯逻辑反例：新增 20 条全 PASS（/tmp/bb_pure2）；上一轮 24 条对更新后源码
  重跑仍全 PASS（/tmp/bb_pure，无 Swift 6 严格并发模式）。
- `scripts/local-gate.sh` 三步全绿（parse / Swift6 typecheck+WMO -O / Helper build）。
- CI Build `32692948908` **success**：182 tests / 27 suites 全过（上轮 167/26）。
- UI Profile `32692948912` **success**（概览页与功耗页 hitches trace 有效，Gate 通过）。

## 二十一、artifact 与安装身份

- artifact：`BatteryBar.zip`（Build 32692948908 产出）。
- 主程序 SHA-256：`a21d33d8…c4d9dc8`（下载与已安装副本一致）。
- Helper SHA-256：`24e04864…f70b8`（下载与已安装副本一致）。
- codesign：`--verify --deep --strict` 主程序与 Helper 均通过。
- 安装：`/Users/mio/Applications/BatteryBar.app`；旧 App 移入
  `~/.Trash/BatteryBar-pre-round3-*.app`；数据备份
  `~/Library/Application Support/BatteryBar-backup-pre-round3-20260824`。

## 二十二、实机运行证据

- 进程 pid 20983：CPU 0.0%，RSS ~13.8MB，零 TCP 连接。
- 概览页 OCR：健康度 98%（来源：系统最大容量）；接电时段卡片标题「本次接电」，
  负增长显示「-5%」中性（无绿色「已充入」）。
- 设置页 OCR：开机自启动行显示「关闭（尚未注册）」（非「当前环境不可用」），
  Toggle 可操作（按要求未替用户开启）；「采样诊断」默认折叠；自动采样三行
  用户语言文案正确。
- journal `snapshots.jsonl`：inode 稳定、按 60s 节奏追加，v5 字段
  （aggregateWindowStart/systemCoverage/temperatureMaximum/temperatureCoverage/
  maximumThermalState）完整，方向字段 ext=true、charging=true 正确。
- `SMAppService.mainApp.status` 保持 .notFound：未替用户注册登录项。
- 旧 refresh-interval.json 原样保留；Helper/launchd 未安装/卸载/修改；
  管理员授权全程未请求。

## 二十三、本轮遗留限制

1. 实机无法自然观测「接电未充电」运行期窗口（本机始终插电充电），该方向
   unknown 不累计由 CI 测试与纯反例证明，非运行期观测。
2. 登录项 .notFound 的注册成功路径仅以 stub 反例与文案验证，未实机点击开启
  （任务约束：不替用户开启）。
3. 接电时段负增长（100→97）以纯反例 + 测试证明展示语义，实机当前为充电正增长。
4. 上轮限制沿用：历史 batteryChargeWh（e3997af 规则产物）不可信、无迁移；
   Helper 仍绑定旧 App CDHash；requiresApproval 需用户手动允许。

## 二十四、外部系统触碰状态（第三轮）

- WebDAV：未启用、无真实请求。Helper/launchd：未安装/卸载/修改。
- 管理员授权：全程未请求。用户数据：journal 只追加、未删除/改写任何历史；
  备份完整可恢复。
- git：普通 push，无 force push、无历史改写；最终 HEAD 与 origin/main 同步。
