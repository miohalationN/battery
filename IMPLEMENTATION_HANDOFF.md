# IMPLEMENTATION_HANDOFF — 事件驱动采样、数据质量模型、分钟聚合与可信续航估算

> 执行 Agent 移交文档，供 assurance/review agent 独立验证。
> 本轮基线：`664c9fe48408a93940e20843149cd5acd14a0459`（origin/main 同步且 clean）。
> 功能提交：A=`2d386b4`（采样/聚合/v5 schema），B=`43bb2eb`（估算器/UI/下游），
> 修复=`e3997af`（Release 独占访问 + 本地门禁 WMO 步）。最终 HEAD 与 origin/main 同步。
> 上一轮移交见 git 历史。

---

## 一、交付范围与角色边界遵守情况

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

## 十四、UI Profile 取证

`.github/workflows/ui-profile.yml` 对概览页与功耗页录制 SwiftUI 求值与 Animation
Hitches trace（本页图表改动后必须取得有效 hitches trace）。本轮 run
32683610852（commit e3997af）**success**：`usage-hitches.trace` 与
`power-hitches.trace` 一次录制即被接受（trace accepted），Gate required traces
步骤校验两份 hitches trace 的 schema 非空后通过；SwiftUI 求值 trace 同样各一份
有效。digest 与原始 trace 已上传为 artifact `ui-profile`（ID 9505291304）。
未以 schema 数宣称零 hitch，hitches 表内容以 artifact 为准供独立复核。

## 十五、遗留限制

1. Helper 更新需要用户一次主动开启 + 管理员授权（§十二），在此之前 CPU/GPU 分项
   读数为 0（明确缺口而非伪造值），v5 快照的 cpuPower/gpuPower/dramPower 相应为 0。
2. 主显示器亮度接口在本机不可读取（`brightnessAvailable=false`），属设备事实而非缺陷；
   UI 如实显示“不可读取”。
3. 估算冷启动：重启后分钟聚合缓冲从零积累，功率证据路径需 ≥10 分钟有效时长，
   期间 UI 显示“正在校准/系统估算”，符合设计。
