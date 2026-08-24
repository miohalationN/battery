import Foundation
import Observation
import IOKit.ps

/// 采样与 UI 状态中枢。
///
/// 隔离模型：整个类隔离在 MainActor，@Observable 状态只允许主线程变更，
/// 消除旧实现 `@unchecked Sendable` 下定时器 / 后台队列并发写状态的数据竞争。
/// SwiftUI 通过 Observation 属性级追踪订阅：视图 body 读到哪个属性，就只在
/// 哪个属性变化时失效——页面根视图不读瓦片等高频字段，历史 Chart 因此不被
/// 高频采样带着重建。阻塞调用（system_profiler 健康度、XPC helper、powermetrics）
/// 通过 Task.detached 移出主线程，结果回写主线程；休眠回调用 MainActor.assumeIsolated
/// 同步执行，避免 willSleep 到系统入睡之间 Task 排队延迟导致睡眠统计丢失。
///
/// 采样节奏（冻结策略，无用户可调刷新频率）：
/// - 任一读数界面可见：基础兜底读取每 5 秒；都不可见：每 15 秒；
/// - 每次界面打开立即读取一次；
/// - IOPowerSources 变化（电源增删/插拔）经 IOPSNotificationCreateRunLoopSource
///   立即读取；低电量模式与热压力走 ProcessInfo 系统通知立即更新；
/// - 通知风暴按约 180ms 合并；stop 之后的事件回调不得写状态；
///   基础读取全部在主线程同步执行，天然串行、不可能重叠。
/// IORegistry 功率/温度没有可靠公开逐字段通知，因此保留兜底轮询。
@MainActor
@Observable
final class PowerSampler {
    private let reader = BatteryReader()
    private let cycleTracker: CycleTracker
    private let sleepWatcher = SleepWatcher()
    private var dispatchTimer: DispatchSourceTimer?
    private var componentPowerTimer: DispatchSourceTimer?
    private var storageTimer: Timer?
    private var liveReadingDemand = LiveReadingDemand()

    // MARK: 系统事件源
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var iopsContextBox: WeakSamplerBox?
    private var systemEventObservers: [NSObjectProtocol] = []
    private var baseReadingCoalescer = NotificationCoalescer()
    private var pendingEventReadTask: Task<Void, Never>?

    private(set) var currentLevel: Double = 0
    private(set) var currentIsCharging: Bool = false
    /// 是否接外接电源。与 currentIsCharging 相互独立：
    /// 满电保持/优化充电暂停/80% 上限都是接电未充电。
    private(set) var currentExternalConnected: Bool = false
    /// 系统负载（瓦特）。接电且无系统遥测时为 0（currentPowerAvailable == false）
    private(set) var currentWattage: Double = 0
    /// 电池包充入/放出功率绝对值（瓦特）；方向由 currentIsCharging 表达
    private(set) var currentBatteryPower: Double = 0
    private(set) var currentPowerAvailable = false
    private(set) var currentPowerIsEstimated = false
    private(set) var currentTemperature: Double = 0
    private(set) var currentVoltage: Double = 0
    private(set) var currentAmperage: Double = 0
    private(set) var currentAdapterInputPower: Double = 0
    private(set) var currentLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var currentThermalState = "正常"
    private(set) var currentInfo: BatteryInfo?
    /// 健康口径（冻结）：UI 首选 macOS system_profiler 报告的「最大容量」；
    /// FullChargeCapacity÷DesignCapacity 仅作回退并标注「容量比估算」，
    /// 不冒充系统健康度。Popover 与主窗口消费同一模型。
    private(set) var healthMetric = BatteryHealthMetric()
    /// 系统健康读取的小时级 TTL 状态；读取本身后台执行，不进采样路径
    private var lastSystemHealthFetchAt: Date?
    private static let systemHealthRefreshTTL: TimeInterval = 3600
    /// 最近一次基础读数轮询成功的时刻。只有明确读取它的小视图会跟随失效。
    private(set) var lastUpdateTime: Date = Date()
    /// 当前基础读数的实际轮询间隔：界面可见 5 秒，否则 15 秒保活。
    private(set) var activeRefreshInterval: TimeInterval = SamplingCadence.backgroundInterval
    private(set) var isForegroundReadingActive = false

    // MARK: 数据质量语义（功耗诊断区消费）
    private(set) var loadMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var batteryPowerMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var temperatureMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var brightnessMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)

    // MARK: 分钟聚合
    private var aggregator = WindowTelemetryAggregator()

    private(set) var cpuPower: Double = 0
    private(set) var gpuPower: Double = 0
    private(set) var dramPower: Double = 0
    /// 最近一次成功的分项功耗采样时刻。超过约 30s 未更新视为陈旧，
    /// UI 只显示绝对瓦数、不再计算占比。
    private(set) var lastComponentPowerAt: Date = .distantPast

    private(set) var helperNeedsUpdate: Bool = false

    // MARK: 续航/充电估算（RuntimeEstimator 结果；nil = 数据不足，正在校准）
    /// 离电续航 App 估算。置信度低于门槛时保持 nil。
    private(set) var dischargeEstimate: EstimationResult?
    /// 充电剩余时间 App 估算（按当前充电速度）。
    private(set) var chargeEstimate: EstimationResult?
    /// IOPowerSources 的系统剩余时间（独立证据，永不与 App 证据静默混算）
    private(set) var systemReportedEstimate: EstimationResult?

    /// 最近完成的分钟聚合环形缓冲（估算器输入，硬上限）
    private var recentAggregates: [MinuteAggregate] = []
    private static let recentAggregatesLimit = 120
    /// 上一轮读取的 IOPS 系统剩余时间（分钟）
    private var lastSystemReportedMinutes: Int = -1
    /// 估算重算节流：除分钟快照/电源切换外最多每 30 秒一次
    private var lastEstimateRecalcAt = Date.distantPast
    private static let estimateRecalcInterval: TimeInterval = 30

    /// Helper 服务开关（默认关闭，用户在 PowerTab 手动开启）
    /// 开启后才会安装 helper 并读取 CPU/GPU 分项功耗
    private(set) var helperEnabled: Bool = UserDefaults.standard.object(forKey: "BatteryBarHelperEnabled") as? Bool ?? false

    // 使用时间统计：按离电周期统计，充电时停止
    private var currentDischargeScreenOn: Int = 0
    private var currentDischargeSleep: Int = 0
    private var lastDischargeScreenOn: Int = 0
    private var lastDischargeSleep: Int = 0
    private var wasExternalConnected: Bool = false
    private var dischargeStartTime: Date?  // 当前离电周期开始时间，用于判断功率是否稳定
    private var lastPlugInTime: Date?       // 上次插电时刻，用于判断是否为短暂插电
    private let shortPlugThreshold: TimeInterval = 30  // 30秒内重插拔视为短暂接触，继续累计统计
    private var saveTick: Int = 0
    private var isComponentPowerSampleInFlight = false
    private var isSleeping: Bool = false
    private var areScreensSleeping: Bool = false
    private var sleepStartTime: Date?
    private var isStarted: Bool = false

    init() {
        // 循环落盘通过闭包注入，便于单元测试用 stub 收集
        self.cycleTracker = CycleTracker(onSave: { DataStore.shared.saveCycle($0) })
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // 从 DataStore 恢复使用时间统计
        let usage = DataStore.shared.loadUsageState()
        lastDischargeScreenOn = usage.lastDischargeScreenOn
        lastDischargeSleep = usage.lastDischargeSleep
        lastPlugInTime = usage.lastPlugInTime

        // 启动时读取当前电源状态
        let reading = reader.readBatteryReading()
        let currentlyPluggedIn = reading?.batteryInfo?.externalConnected
            ?? reading?.powerSource.isPluggedIn
            ?? usage.wasExternalConnected

        if currentlyPluggedIn {
            // 启动时在充电：保留上次统计，当前统计清零
            wasExternalConnected = true
            currentDischargeScreenOn = 0
            currentDischargeSleep = 0
        } else {
            // 启动时离电：无法确定之前拔电时间，从0开始重新统计
            wasExternalConnected = false
            currentDischargeScreenOn = 0
            currentDischargeSleep = 0
            dischargeStartTime = Date()
        }

        // 接线 SleepWatcher：通过系统休眠/唤醒事件维护 isSleeping 与睡眠时长，
        // 并在睡眠开始立即截断聚合器连续量
        sleepWatcher.onSleep = { [weak self] in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        sleepWatcher.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        sleepWatcher.onScreensSleep = { [weak self] in
            MainActor.assumeIsolated { self?.handleScreensSleep() }
        }
        sleepWatcher.onScreensWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleScreensWake() }
        }
        sleepWatcher.start()

        registerSystemEventSources()

        if let reading {
            applyBaseReading(reading)
        }
        sampleStorage()

        // 健康口径：先以 IORegistry 容量比作为「估算」回退占位（明确标注），
        // 随后后台读取 macOS 系统报告值（首选口径）覆盖；不因容量比>0 而跳过。
        applyFallbackHealth()
        refreshSystemHealthInBackground()

        let reader = reader
        // 后台预加载静态信息（机器型号、序列号、制造商），避免主线程每秒 spawn system_profiler。
        // 加载完成无需广播：下一次轻量采样会经 shouldPublishMetadata 比对出新字段并写入 currentInfo，
        // Observation 只失效读取该属性的视图。
        reader.prefetchStaticInfo(
            includeBatteryFallback: reading?.batteryInfo?.serialNumber.isEmpty ?? true
        )

        // Helper 服务：启动时只做版本检查，不可因应用升级在后台突然弹管理员授权。
        // 版本不匹配时关闭运行态开关；用户再次主动开启才执行安装/更新。
        if helperEnabled {
            Task { @MainActor in
                let needsUpdate = await Task.detached(priority: .utility) {
                    reader.needsHelperUpdate()
                }.value
                self.helperNeedsUpdate = needsUpdate
                if needsUpdate {
                    UserDefaults.standard.set(false, forKey: "BatteryBarHelperEnabled")
                    self.helperEnabled = false
                    self.stopComponentPowerTimer()
                } else {
                    self.restartComponentPowerTimer(sampleImmediately: true)
                }
            }
        } else {
            Task { @MainActor in
                let needsUpdate = await Task.detached(priority: .utility) {
                    reader.dormantInstalledHelperNeedsUpdate()
                }.value
                self.helperNeedsUpdate = needsUpdate
            }
        }

        // 存储定时器（Timer + target/selector 在主 RunLoop 触发，无隔离问题）
        let st = Timer(timeInterval: SamplingCadence.historyInterval, target: self, selector: #selector(fireStorage), userInfo: nil, repeats: true)
        RunLoop.main.add(st, forMode: .common)
        storageTimer = st

        // 基础读数定时器
        restartTimer()
    }

    func stop() {
        // 先关闭运行态门控：此后到达的定时器回调、事件回调、迟到 Task 一律
        // 不得写状态或 journal；随后才撤销各事件源与定时器。
        isStarted = false
        pendingEventReadTask?.cancel()
        pendingEventReadTask = nil
        dispatchTimer?.cancel()
        dispatchTimer = nil
        stopComponentPowerTimer()
        storageTimer?.invalidate()
        storageTimer = nil
        sleepWatcher.stop()
        unregisterSystemEventSources()
        persistUsageState()
    }

    // MARK: - 系统事件（IOPS / 低电量模式 / 热压力）

    /// 注册事件源：IOPS 电源变化用专用 RunLoop source；低电量模式与热压力用
    /// Foundation 系统通知。回调统一进入合并窗口后触发立即读取。
    private func registerSystemEventSources() {
        // IOPS 回调是 C 函数指针，不能捕获 Swift 上下文；通过 context 指针
        // 传回弱引用盒子。source 只挂在主 RunLoop 上，注销在主线程同步完成，
        // 回调内 assumeIsolated 安全且不会在 stop 后再触发。
        let box = WeakSamplerBox(self)
        iopsContextBox = box
        let context = Unmanaged.passUnretained(box).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let box = Unmanaged<WeakSamplerBox>.fromOpaque(rawContext).takeUnretainedValue()
            guard let sampler = box.sampler as? PowerSampler else { return }
            MainActor.assumeIsolated { sampler.handleSystemEvent() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
        }

        let center = NotificationCenter.default
        systemEventObservers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemEvent() }
        })
        systemEventObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemEvent() }
        })
    }

    private func unregisterSystemEventSources() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        iopsContextBox = nil
        for observer in systemEventObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        systemEventObservers.removeAll()
    }

    /// 事件入口：合并窗口内的重复通知只产生一次读取。
    private func handleSystemEvent() {
        guard isStarted else { return }
        switch baseReadingCoalescer.eventReceived(now: Date()) {
        case .fireNow:
            sampleUI()
        case .delay(let delay):
            scheduleDelayedEventRead(after: delay)
        case .mergeIntoPending:
            break
        }
    }

    private func scheduleDelayedEventRead(after delay: TimeInterval) {
        pendingEventReadTask?.cancel()
        pendingEventReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isStarted else { return }
            self.baseReadingCoalescer.fireCompleted(at: Date())
            self.sampleUI()
        }
    }

    // MARK: - 界面可见性

    /// 登记主窗口 / 菜单栏弹窗的可见性。任一界面打开即立即采样并切到前台节奏；
    /// 只有最后一个界面关闭后才回到后台低频，避免两个界面互相覆盖生命周期。
    func setReadingSurface(_ surface: LiveReadingSurface, visible: Bool) {
        let oldInterval = effectiveRefreshInterval
        guard liveReadingDemand.set(surface, visible: visible) else { return }

        let active = liveReadingDemand.hasVisibleSurface
        if active != isForegroundReadingActive {
            isForegroundReadingActive = active
        }
        let newInterval = effectiveRefreshInterval

        guard isStarted else {
            activeRefreshInterval = newInterval
            return
        }

        // 每次打开一个读数界面都先取一次，不必等待下一个 timer deadline。
        if visible { sampleUI() }
        if oldInterval != newInterval {
            restartTimer(sampleImmediately: false)
        }
    }

    private var effectiveRefreshInterval: TimeInterval {
        SamplingCadence.effectiveInterval(hasVisibleSurface: liveReadingDemand.hasVisibleSurface)
    }

    /// 重启基础读数定时器。前台 5 秒、后台 15 秒；间隔是兜底读取尝试频率，
    /// 不代表电池驱动每轮都会发布新值（驱动可能数秒至十余秒才批量发布）。
    private func restartTimer(sampleImmediately: Bool = false) {
        dispatchTimer?.cancel()
        let interval = effectiveRefreshInterval
        if activeRefreshInterval != interval { activeRefreshInterval = interval }
        if sampleImmediately { sampleUI() }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let leewayMilliseconds = isForegroundReadingActive ? 500 : 2_000
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sampleUI()
            }
        }
        timer.resume()
        dispatchTimer = timer
    }

    /// 高级分项采样独立于基础读数和界面可见性。用户主动开启后，Helper 与 App
    /// 均按 10 秒节奏产出/读取缓存，给每分钟历史点提供真实的新鲜分项样本；默认关闭。
    private func restartComponentPowerTimer(sampleImmediately: Bool) {
        stopComponentPowerTimer()
        guard isStarted, helperEnabled else { return }
        if sampleImmediately { sampleComponentPower() }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + SamplingCadence.componentPowerInterval,
            repeating: SamplingCadence.componentPowerInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sampleComponentPower()
            }
        }
        timer.resume()
        componentPowerTimer = timer
    }

    private func stopComponentPowerTimer() {
        componentPowerTimer?.cancel()
        componentPowerTimer = nil
    }

    private func sampleComponentPower() {
        guard helperEnabled, !isComponentPowerSampleInFlight else { return }
        isComponentPowerSampleInFlight = true
        let reader = reader
        Task { @MainActor in
            let component = await Task.detached(priority: .utility) {
                reader.readComponentPower()
            }.value
            self.isComponentPowerSampleInFlight = false

            // 关闭开关或 sampler stop 后，迟到的 XPC 结果不得重新写回已清零状态。
            guard self.helperEnabled, self.isStarted else { return }
            let age = Date().timeIntervalSince(component.sampledAt)
            guard component.isAvailable, age >= 0, age < 120 else { return }
            // powermetrics 明确提供硬件采样时间，质量模型如实记录
            self.lastComponentPowerAt = component.sampledAt
            if abs(self.cpuPower - component.cpu) > 0.02 { self.cpuPower = component.cpu }
            if abs(self.gpuPower - component.gpu) > 0.02 { self.gpuPower = component.gpu }
            if abs(self.dramPower - component.dram) > 0.02 { self.dramPower = component.dram }
        }
    }

    // MARK: - Sleep / Wake

    private func handleSleep() {
        isSleeping = true
        areScreensSleeping = true
        sleepStartTime = Date()
        let now = Date()
        // 睡眠期间屏幕必然熄灭；连续量立即截断，不得把睡前功率延伸进睡眠窗口
        aggregator.setState(screenOn: false, at: now)
        aggregator.truncateContinuity(at: now)
    }

    private func handleScreensSleep() {
        areScreensSleeping = true
        aggregator.setState(screenOn: false, at: Date())
    }

    private func handleScreensWake() {
        guard !isSleeping else { return }
        areScreensSleeping = false
        aggregator.setState(screenOn: true, at: Date())
    }

    private func handleWake() {
        // 系统睡眠期间 Timer 不会被触发，这里按实际睡眠时长补足睡眠统计
        // 只在离电期间计入（充电时睡眠不算"电池使用时间"）
        if let start = sleepStartTime {
            let slept = Date().timeIntervalSince(start)
            if !wasExternalConnected {
                currentDischargeSleep += Int(slept / 60)
            }
            sleepStartTime = nil
        }
        isSleeping = false
        areScreensSleeping = false
        persistUsageState()
        // 唤醒后立即重新读取，不等下一个兜底 deadline；系统健康也按 TTL 刷新
        if isStarted {
            sampleUI()
            refreshSystemHealthInBackground()
        }
    }

    // MARK: - Usage state persistence

    private func persistUsageState() {
        var state = UsageState()
        state.currentDischargeScreenOn = currentDischargeScreenOn
        state.currentDischargeSleep = currentDischargeSleep
        state.lastDischargeScreenOn = lastDischargeScreenOn
        state.lastDischargeSleep = lastDischargeSleep
        state.wasExternalConnected = wasExternalConnected
        state.lastPlugInTime = lastPlugInTime
        DataStore.shared.saveUsageState(state)
    }

    // MARK: - 基础读取

    private func sampleUI() {
        // stop 后到达的回调/迟到定时器一律不得写状态
        guard isStarted else { return }
        // IOPS 在睡眠切换/驱动重载时可能瞬时失败。此时保留上次 UI 状态，不能把
        // 失败合成为 0%/离电并污染插拔状态机。
        guard let reading = reader.readBatteryReading() else { return }
        applyBaseReading(reading)
    }

    /// 后台低频刷新系统健康度：启动一次、TTL 到期或唤醒后触发；
    /// system_profiler 在 detached 任务执行，绝不阻塞主线程、不进 5/15 秒路径。
    private func refreshSystemHealthInBackground() {
        guard BatteryHealthMetric.shouldRefresh(
            lastFetchAt: lastSystemHealthFetchAt, now: Date(), ttl: Self.systemHealthRefreshTTL
        ) else { return }
        lastSystemHealthFetchAt = Date()
        let reader = reader
        Task { @MainActor in
            let reading = await Task.detached(priority: .utility) {
                reader.readSystemHealth()
            }.value
            guard isStarted else { return }
            let resolved = BatteryHealthMetric.resolved(
                systemReading: reading,
                maxCapacityMah: currentInfo?.maxCapacity ?? 0,
                designCapacityMah: currentInfo?.designCapacity ?? 0
            )
            if healthMetric != resolved { healthMetric = resolved }
        }
    }

    /// 回退口径：FullChargeCapacity÷DesignCapacity，标注「容量比估算」；
    /// 全部缺失时保持不可用（percent=0），不默认 100。
    private func applyFallbackHealth() {
        let fallback = BatteryHealthMetric.resolved(
            systemReading: nil,
            maxCapacityMah: currentInfo?.maxCapacity ?? 0,
            designCapacityMah: currentInfo?.designCapacity ?? 0
        )
        if healthMetric != fallback { healthMetric = fallback }
    }

    /// 应用一轮成功的基础读取：发布可观察状态、更新质量样本、喂入聚合器。
    private func applyBaseReading(_ reading: BatteryReader.BatteryReading) {
        let ps = reading.powerSource
        let info = reading.batteryInfo
        let readAt = reading.readAt
        let isPluggedIn = info?.externalConnected ?? ps.isPluggedIn
        let previousLevel = currentLevel
        let previousCharging = currentIsCharging
        let previousExternalConnected = currentExternalConnected

        // 插拔检测（立即响应，不等 sampleStorage 的每分钟检查）
        if wasExternalConnected && !isPluggedIn {
            // 拔电
            let plugDuration = lastPlugInTime.map { readAt.timeIntervalSince($0) } ?? .infinity
            if plugDuration < shortPlugThreshold {
                // 短暂插电（< 30秒）：继续累计统计，不重置
                // dischargeStartTime 保持 nil（功率不需要重新稳定，插电时间极短）
            } else {
                // 正常拔电：清零当前离电统计
                currentDischargeScreenOn = 0
                currentDischargeSleep = 0
                dischargeStartTime = readAt
            }
        } else if !wasExternalConnected && isPluggedIn {
            // 插电：把当前统计保存为"上次使用"
            if currentDischargeScreenOn > 0 || currentDischargeSleep > 0 {
                lastDischargeScreenOn = currentDischargeScreenOn
                lastDischargeSleep = currentDischargeSleep
            }
            dischargeStartTime = nil
            lastPlugInTime = readAt
        }
        wasExternalConnected = isPluggedIn

        // 只在值真正变化时写 @Observable 属性：Observation 虽是属性级失效，
        // 无条件写仍会让读取该属性的视图逐 tick 重算。
        // 0.05W 阈值滤掉遥测抖动；level/isCharging/温度等低频字段按相等门控。
        let wattage = info?.systemPower ?? info?.wattage ?? 0
        if ps.level != currentLevel { currentLevel = ps.level }
        if ps.isCharging != currentIsCharging { currentIsCharging = ps.isCharging }
        if isPluggedIn != currentExternalConnected { currentExternalConnected = isPluggedIn }
        if abs(wattage - currentWattage) > 0.05 { currentWattage = wattage }
        if abs((info?.batteryPower ?? 0) - currentBatteryPower) > 0.05 {
            currentBatteryPower = info?.batteryPower ?? 0
        }
        if (info?.systemPowerAvailable ?? false) != currentPowerAvailable {
            currentPowerAvailable = info?.systemPowerAvailable ?? false
        }
        if (info?.systemPowerIsEstimated ?? false) != currentPowerIsEstimated {
            currentPowerIsEstimated = info?.systemPowerIsEstimated ?? false
        }
        if (info?.temperature ?? 0) != currentTemperature { currentTemperature = info?.temperature ?? 0 }
        if (info?.voltage ?? 0) != currentVoltage { currentVoltage = info?.voltage ?? 0 }
        if (info?.instantAmperage ?? 0) != currentAmperage { currentAmperage = info?.instantAmperage ?? 0 }
        if abs((info?.adapterInputPower ?? 0) - currentAdapterInputPower) > 0.05 {
            currentAdapterInputPower = info?.adapterInputPower ?? 0
        }
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled != currentLowPowerModeEnabled {
            currentLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        }
        let thermalState = Self.thermalStateLabel(processInfo.thermalState)
        if thermalState != currentThermalState { currentThermalState = thermalState }
        // currentInfo 只承载界面使用的元数据。电压、电流、温度和功率已有独立
        // 可观察字段；若把这些高频值也纳入 BatteryInfo 等值比较，会平白多触发
        // 一次读取该属性的视图更新。
        if shouldPublishMetadata(info) {
            currentInfo = info
            // 容量信息更新时，若系统健康值尚未取得，同步刷新容量比估算占位
            if !healthMetric.sourceIsSystem { applyFallbackHealth() }
        }
        lastUpdateTime = readAt

        updateQualityMetrics(reading)
        feedAggregator(reading)

        // IOPS 系统剩余时间作为独立证据保留（不透明值，不与 App 证据混算）
        lastSystemReportedMinutes = ps.timeRemaining

        // 状态栏只关心电量与充电态；相同数据不再每个轮询 tick 发通知。
        let statusChanged = previousLevel != currentLevel || previousCharging != currentIsCharging
        if statusChanged {
            NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)
            NotificationManager.shared.checkLowBattery(level: currentLevel, isCharging: currentIsCharging)
            if previousCharging && !currentIsCharging && currentLevel >= 100 {
                NotificationManager.shared.checkFullCharge(level: currentLevel, wasCharging: true)
            }
        }

        // 电源状态切换（插拔/充放转换）是估算的合法重算触发
        if isPluggedIn != previousExternalConnected || previousCharging != currentIsCharging {
            recalculateEstimates()
        } else if Date().timeIntervalSince(lastEstimateRecalcAt) >= Self.estimateRecalcInterval {
            // 兜底重算节奏：最多每 30 秒一次，绝不扫描全量历史
            recalculateEstimates()
        }
    }

    /// 更新数据质量样本。同值重复读取只推进 readAt；来源/估算标记来自本轮 provenance。
    private func updateQualityMetrics(_ reading: BatteryReader.BatteryReading) {
        let info = reading.batteryInfo
        let provenance = reading.provenance
        let readAt = reading.readAt

        loadMetric.observe(
            reading.trustedSystemLoad,
            source: provenance.systemLoadSource == .unavailable && reading.trustedSystemLoad == nil
                ? .unavailable : provenance.systemLoadSource,
            isEstimated: provenance.systemLoadIsEstimated,
            readAt: readAt
        )
        let batteryPowerAvailable = info?.batteryPowerAvailable ?? false
        let batteryPowerValue = info?.batteryPower ?? 0
        // 可信零瓦 = available + some(0)；没读到功率 = unavailable + nil。
        // 兼容哨兵 0（available=false 时的 batteryPower==0）不得进入质量模型。
        batteryPowerMetric.observe(
            batteryPowerAvailable ? .some(batteryPowerValue) : .none,
            source: batteryPowerAvailable ? provenance.batteryPowerSource : .unavailable,
            isEstimated: provenance.batteryPowerSource == .voltageCurrentDerived,
            readAt: readAt
        )
        let temperature = info?.temperature ?? 0
        temperatureMetric.observe(
            temperature > 0.25 ? temperature : nil,
            source: provenance.temperatureSource ?? .unavailable,
            readAt: readAt
        )
        let brightness = reader.readDisplayBrightness()
        brightnessMetric.observe(
            brightness.brightness,
            source: brightness.brightness == nil ? .unavailable : .displayIOKit,
            readAt: brightness.readAt
        )
    }

    /// 把本轮可信观测喂入分钟聚合器；离散状态先按当前真实值登记，
    /// 使切换时刻尽量贴近通知时刻。
    private func feedAggregator(_ reading: BatteryReader.BatteryReading) {
        let info = reading.batteryInfo
        let readAt = reading.readAt
        let processInfo = ProcessInfo.processInfo
        aggregator.setState(
            screenOn: !isSleeping && !areScreensSleeping,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalStateOrdinal: thermalOrdinal(processInfo.thermalState),
            thermalStateLabel: Self.thermalStateLabel(processInfo.thermalState),
            at: readAt
        )
        let temperature = info?.temperature ?? 0
        aggregator.observe(WindowTelemetryAggregator.Observation(
            date: readAt,
            trustedSystemLoad: reading.trustedSystemLoad,
            batteryChannel: reading.batteryChannel,
            temperatureCelsius: temperature > 0.25 ? temperature : nil,
            expectedInterval: effectiveRefreshInterval
        ))
    }

    /// 估算器重算：输入有界（最近 120 快照 + 最近 120 分钟聚合），
    /// 只在新分钟快照、电源状态切换或最多每 30 秒触发。
    private func recalculateEstimates() {
        lastEstimateRecalcAt = Date()
        var input = RuntimeEstimator.Inputs()
        input.now = Date()
        input.currentLevel = currentLevel
        input.isCharging = currentIsCharging
        input.externalConnected = currentInfo?.externalConnected ?? currentExternalConnected
        input.snapshots = DataStore.shared.recentSnapshots(120)
        input.minuteAggregates = recentAggregates
        input.fullChargeCapacityMah = currentInfo?.maxCapacity ?? 0
        input.voltageMV = currentVoltage
        input.systemReportedMinutes = lastSystemReportedMinutes

        dischargeEstimate = RuntimeEstimator.dischargeEstimate(input)
        chargeEstimate = RuntimeEstimator.chargeEstimate(input)
        systemReportedEstimate = RuntimeEstimator.systemReportedEstimate(input)
    }

    @objc private func fireStorage() {
        guard isStarted else { return }
        sampleStorage()
    }

    private func shouldPublishMetadata(_ info: BatteryInfo?) -> Bool {
        guard let info else { return currentInfo != nil }
        guard let currentInfo else { return true }
        return info.designCapacity != currentInfo.designCapacity
            || info.maxCapacity != currentInfo.maxCapacity
            || info.cycleCount != currentInfo.cycleCount
            || info.serialNumber != currentInfo.serialNumber
            || info.manufacturer != currentInfo.manufacturer
            || info.isCharging != currentInfo.isCharging
            || info.externalConnected != currentInfo.externalConnected
            || info.deviceName != currentInfo.deviceName
            || info.chemistry != currentInfo.chemistry
            || info.adapterWatts != currentInfo.adapterWatts
            || info.adapterProtocol != currentInfo.adapterProtocol
    }

    /// 速率 EMA 平滑已随旧 DrainRateCalculator 路径移除：
    /// 估算证据不足时必须显示「正在校准」，不得用平滑值填补。

    private func sampleStorage() {
        // stop 后到达的定时器回调一律不得写 journal 或状态
        guard isStarted else { return }
        // 采集失败时跳过这一分钟；伪造 0% 快照比一个明确的数据缺口更有害。
        guard let reading = reader.readBatteryReading() else { return }
        applyBaseReading(reading)
        let ps = reading.powerSource
        let info = reading.batteryInfo
        let isPluggedIn = info?.externalConnected ?? ps.isPluggedIn

        let componentAge = Date().timeIntervalSince(lastComponentPowerAt)
        let hasFreshComponents = helperEnabled && componentAge >= 0 && componentAge <= 30
        var snapshot = BatterySnapshot(
            timestamp: reading.readAt,
            level: ps.level,
            isCharging: ps.isCharging,
            wattage: info?.systemPower ?? info?.wattage ?? 0,
            temperature: info?.temperature ?? 0,
            screenOn: !isSleeping && !areScreensSleeping,
            batteryPower: info?.batteryPower ?? 0,
            systemPowerAvailable: info?.systemPowerAvailable ?? false,
            systemPowerIsEstimated: info?.systemPowerIsEstimated ?? false,
            // Helper 失败或样本过期时写明确缺口（0），绝不把旧分项值无限复制进历史。
            // 显示器瓦数不再伪造：displayPower 恒为 0，亮度以 v5 字段单独记录。
            cpuPower: hasFreshComponents ? cpuPower : 0,
            gpuPower: hasFreshComponents ? gpuPower : 0,
            displayPower: 0,
            dramPower: hasFreshComponents ? dramPower : 0,
            externalConnected: isPluggedIn,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.thermalStateLabel(ProcessInfo.processInfo.thermalState)
        )
        if let aggregate = aggregator.takeCompletedAggregate() {
            let brightness = brightnessMetric
            let brightReadable = brightness.availability == .available
            snapshot.apply(
                minuteAggregate: aggregate,
                displayBrightness: brightReadable ? brightness.value : nil,
                brightnessAvailable: brightReadable,
                brightnessReadAt: brightReadable ? brightness.readAt : nil
            )
            // 估算器输入环形缓冲：只保留最近 N 个完成窗口，硬上限防膨胀
            recentAggregates.append(aggregate)
            if recentAggregates.count > Self.recentAggregatesLimit {
                recentAggregates.removeFirst(recentAggregates.count - Self.recentAggregatesLimit)
            }
        }
        DataStore.shared.saveSnapshot(snapshot)

        // 新分钟快照是估算的合法重算触发
        recalculateEstimates()

        // 系统健康的小时级 TTL 刷新：仅一次廉价日期比较，读取在后台执行，
        // 绝不随 5/15 秒基础采样重复启动 system_profiler。
        refreshSystemHealthInBackground()

        // 只在离电时累加使用时间
        // awake 计入屏幕亮起；睡眠期间 Timer 不触发，实际睡眠时长由 onWake 补足
        if !isPluggedIn {
            if isSleeping || areScreensSleeping {
                currentDischargeSleep += 1
            } else {
                currentDischargeScreenOn += 1
            }
        }

        // 离电时段检测只认插拔状态；接电未充电（满电保持/优化充电暂停）不产生记录
        cycleTracker.update(isPluggedIn: isPluggedIn, level: ps.level, batteryPower: info?.batteryPower ?? 0)

        // 每 5 分钟落盘一次
        saveTick += 1
        if saveTick % 5 == 0 {
            persistUsageState()
        }
    }

    func openBatterySettings() {
        reader.openBatterySettings()
    }

    private func thermalOrdinal(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "偏高"
        case .serious: "较高"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }

    /// 用户手动开启 Helper：安装（osascript 弹一次管理员密码框）在后台线程执行，
    /// 主线程保持响应；仅当安装成功后才写入 UserDefaults，避免密码取消/错误时开关仍显示开启。
    func enableHelperInBackground() async {
        let reader = reader
        let installed = await Task.detached(priority: .userInitiated) {
            reader.installHelperIfNeeded()
        }.value
        if installed {
            UserDefaults.standard.set(true, forKey: "BatteryBarHelperEnabled")
            helperEnabled = true
            helperNeedsUpdate = false
            restartComponentPowerTimer(sampleImmediately: true)
        }
        helperNeedsUpdate = !installed
    }

    /// 用户手动关闭 Helper：后台卸载 root 守护进程（弹一次管理员密码框），
    /// 停止读取分项功耗并清零数据。
    /// 用户取消密码框时 launchd job 可能保留，但 app 停止调用；helper 5.0 的
    /// powermetrics 60s 空闲自停，Helper 进程本身也会退出。
    func disableHelperInBackground() async {
        stopComponentPowerTimer()
        UserDefaults.standard.set(false, forKey: "BatteryBarHelperEnabled")
        helperEnabled = false
        let reader = reader
        await Task.detached(priority: .userInitiated) {
            _ = reader.uninstallHelper()
        }.value
        cpuPower = 0
        gpuPower = 0
        dramPower = 0
        lastComponentPowerAt = .distantPast
    }

    /// 当前离电周期的亮屏时间（离电时显示）
    var screenOnTime: Int { currentDischargeScreenOn }
    /// 当前离电周期的休眠时间（离电时显示）
    var sleepTime: Int { currentDischargeSleep }
    /// 上次离电周期的亮屏时间（充电时显示）
    var lastScreenOnTime: Int { lastDischargeScreenOn }
    /// 上次离电周期的休眠时间（充电时显示）
    var lastSleepTime: Int { lastDischargeSleep }
    /// 当前离电周期开始时间（拔电时刻），用于判断功率是否稳定
    var currentDischargeStart: Date? { dischargeStartTime }
    /// 电源三态：charging / onPowerNotCharging / onBattery。
    /// 满电保持、优化充电暂停、80% 上限都是 onPowerNotCharging。
    var powerSourceState: PowerSourceState {
        PowerSourceState(externalConnected: currentExternalConnected, isCharging: currentIsCharging)
    }

    /// IOPS C 回调与 MainActor 采样器之间的弱引用桥。
    /// 生命周期完全由 PowerSampler 在主线程管理：注册时创建、注销时置空，
    /// 因此回调触发时盒子必然存活，不存在跨线程释放竞争。
    private final class WeakSamplerBox {
        weak var sampler: AnyObject?
        init(_ sampler: AnyObject) { self.sampler = sampler }
    }
}
