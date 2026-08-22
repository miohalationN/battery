import Foundation
import Observation

/// 采样与 UI 状态中枢。
///
/// 隔离模型：整个类隔离在 MainActor，@Observable 状态只允许主线程变更，
/// 消除旧实现 `@unchecked Sendable` 下定时器 / 后台队列并发写状态的数据竞争。
/// SwiftUI 通过 Observation 属性级追踪订阅：视图 body 读到哪个属性，就只在
/// 哪个属性变化时失效——页面根视图不读瓦片等高频字段，历史 Chart 因此不被
/// 每秒采样带着重建。阻塞调用（system_profiler 健康度、XPC helper、powermetrics）
/// 通过 Task.detached 移出主线程，结果回写主线程；休眠回调用 MainActor.assumeIsolated
/// 同步执行，避免 willSleep 到系统入睡之间 Task 排队延迟导致睡眠统计丢失。
@MainActor
@Observable
final class PowerSampler {
    private let reader = BatteryReader()
    private let cycleTracker: CycleTracker
    private let sleepWatcher = SleepWatcher()
    private var dispatchTimer: DispatchSourceTimer?
    private var storageTimer: Timer?
    private var refreshObserver: NSObjectProtocol?

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
    private(set) var currentInfo: BatteryInfo?
    private(set) var systemHealthPercent: Double = 100
    /// 最近一次采样时刻（视图不观察；每秒写它只会让状态栏刷新，不该波及任何视图）
    private(set) var lastUpdateTime: Date = Date()

    private(set) var cpuPower: Double = 0
    private(set) var gpuPower: Double = 0
    private(set) var displayPower: Double = 0
    private(set) var dramPower: Double = 0
    /// 最近一次成功的分项功耗采样时刻。超过约 30s 未更新视为陈旧，
    /// UI 只显示绝对瓦数、不再计算占比。
    private(set) var lastComponentPowerAt: Date = .distantPast

    private(set) var helperNeedsUpdate: Bool = false

    // 放电/充电速率缓存：每 30 个 UI tick 重算一次，避免 View body 每 tick 全量扫描 DataStore
    private(set) var cachedDrainRate: Double = 0
    private(set) var cachedChargeRate: Double = 0
    private var lastRateCalculationAt = Date.distantPast
    private let rateCacheInterval: TimeInterval = 30

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
    private var lastComponentPowerSampleAt = Date.distantPast
    private var isComponentPowerSampleInFlight = false
    private let componentPowerInterval: TimeInterval = 15
    private var isSleeping: Bool = false
    private var areScreensSleeping: Bool = false
    private var sleepStartTime: Date?
    private var isStarted: Bool = false
    private(set) var uiInterval: TimeInterval = 1

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

        // 从 DataStore 恢复用户自定义的 UI 刷新间隔（重启后不丢失）
        uiInterval = DataStore.shared.currentRefreshInterval()

        // 启动时读取当前电源状态
        let ps = reader.readPowerSource()
        let info = reader.readBatteryInfo()
        let currentlyPluggedIn = info?.externalConnected ?? ps.isPluggedIn

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

        // 接线 SleepWatcher：通过系统休眠/唤醒事件维护 isSleeping 与睡眠时长
        // NSWorkspace 通知在主线程派发（SleepWatcher 内 queue: .main），assumeIsolated 安全
        sleepWatcher.onSleep = { [weak self] in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        sleepWatcher.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        sleepWatcher.onScreensSleep = { [weak self] in
            MainActor.assumeIsolated { self?.areScreensSleeping = true }
        }
        sleepWatcher.onScreensWake = { [weak self] in
            MainActor.assumeIsolated { self?.areScreensSleeping = false }
        }
        sleepWatcher.start()

        // 观察刷新间隔变更通知（object 为 Double）
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .init("RefreshIntervalChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let interval = note.object as? Double
            Task { @MainActor [weak self] in
                guard let interval else { return }
                self?.uiInterval = interval
                self?.restartTimer()
            }
        }

        sampleUI()
        sampleStorage()

        // 后台读取系统健康度（system_profiler 耗时 1-3s，不能阻塞主线程）
        let reader = reader
        Task { @MainActor in
            let health = await Task.detached(priority: .userInitiated) {
                reader.readSystemHealthPercent()
            }.value
            self.systemHealthPercent = health
        }

        // 后台预加载静态信息（机器型号、序列号、制造商），避免主线程每秒 spawn system_profiler。
        // 加载完成无需广播：下一次轻量采样会经 shouldPublishMetadata 比对出新字段并写入 currentInfo，
        // Observation 只失效读取该属性的视图。
        reader.prefetchStaticInfo()

        // Helper 服务：仅在用户开启时检查/安装（XPC 版本检测 + osascript 均为阻塞调用）
        if helperEnabled {
            Task { @MainActor in
                let needsUpdate = await Task.detached(priority: .utility) {
                    reader.needsHelperUpdate()
                }.value
                guard needsUpdate else { return }
                let installed = await Task.detached(priority: .utility) {
                    reader.installHelperIfNeeded()
                }.value
                self.helperNeedsUpdate = !installed
            }
        }

        // 存储定时器（Timer + target/selector 在主 RunLoop 触发，无隔离问题）
        let st = Timer(timeInterval: 60, target: self, selector: #selector(fireStorage), userInfo: nil, repeats: true)
        RunLoop.main.add(st, forMode: .common)
        storageTimer = st

        // UI 定时器
        restartTimer()
    }

    func stop() {
        dispatchTimer?.cancel()
        dispatchTimer = nil
        storageTimer?.invalidate()
        storageTimer = nil
        sleepWatcher.stop()
        if let obs = refreshObserver {
            NotificationCenter.default.removeObserver(obs)
            refreshObserver = nil
        }
        persistUsageState()
        isStarted = false
    }

    @objc private func fireStorage() {
        sampleStorage()
    }

    /// 重启 UI 定时器（应用新的刷新间隔）
    private func restartTimer() {
        dispatchTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 给系统少量合并唤醒空间，减少菜单栏常驻应用的定时器能耗。
        let leewayMilliseconds = Int(max(100, min(500, uiInterval * 100)))
        timer.schedule(
            deadline: .now(),
            repeating: uiInterval,
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

    // MARK: - Sleep / Wake

    private func handleSleep() {
        isSleeping = true
        areScreensSleeping = true
        sleepStartTime = Date()
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

    private func sampleUI() {
        let ps = reader.readPowerSource()
        let info = reader.readBatteryInfo()

        let previousCharging = currentIsCharging
        let isPluggedIn = info?.externalConnected ?? ps.isPluggedIn

        // 插拔检测（每秒检查，立即响应，不等 sampleStorage 的每分钟检查）
        if wasExternalConnected && !isPluggedIn {
            // 拔电
            let plugDuration = lastPlugInTime.map { Date().timeIntervalSince($0) } ?? .infinity
            if plugDuration < shortPlugThreshold {
                // 短暂插电（< 30秒）：继续累计统计，不重置
                // dischargeStartTime 保持 nil（功率不需要重新稳定，插电时间极短）
            } else {
                // 正常拔电：清零当前离电统计
                currentDischargeScreenOn = 0
                currentDischargeSleep = 0
                dischargeStartTime = Date()
            }
        } else if !wasExternalConnected && isPluggedIn {
            // 插电：把当前统计保存为"上次使用"
            if currentDischargeScreenOn > 0 || currentDischargeSleep > 0 {
                lastDischargeScreenOn = currentDischargeScreenOn
                lastDischargeSleep = currentDischargeSleep
            }
            dischargeStartTime = nil
            lastPlugInTime = Date()
        }
        wasExternalConnected = isPluggedIn

        // 只在值真正变化时写 @Observable 属性：Observation 虽是属性级失效，
        // 每秒无条件写仍会让读取该属性的视图（状态栏数字、英雄卡）逐秒重算。
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
        // currentInfo 只承载界面使用的元数据。电压、电流、温度和功率已有独立
        // 可观察字段；若把这些高频值也纳入 BatteryInfo 等值比较，会平白多触发
        // 一次读取该属性的视图更新。
        if shouldPublishMetadata(info) { currentInfo = info }
        lastUpdateTime = Date()

        // 通知状态栏 AppDelegate 刷新 button.title（title 不自动响应 @Published）
        NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)

        // 检查通知
        NotificationManager.shared.checkLowBattery(level: currentLevel, isCharging: currentIsCharging)
        if previousCharging && !currentIsCharging && currentLevel >= 100 {
            NotificationManager.shared.checkFullCharge(level: currentLevel, wasCharging: true)
        }

        // 分项功耗按墙上时间采样，不依赖用户设置的 UI 间隔；同时禁止慢 XPC
        // 请求重叠，避免 helper 异常时后台堆积 detached task。
        let now = Date()
        if helperEnabled,
           !isComponentPowerSampleInFlight,
           now.timeIntervalSince(lastComponentPowerSampleAt) >= componentPowerInterval {
            lastComponentPowerSampleAt = now
            isComponentPowerSampleInFlight = true
            let reader = reader
            Task { @MainActor in
                let (component, display) = await Task.detached(priority: .userInitiated) { () -> (ComponentPower, Double) in
                    (reader.readComponentPower(), reader.estimateDisplayPower())
                }.value
                self.isComponentPowerSampleInFlight = false
                if component.cpu > 0 || component.gpu > 0 || component.dram > 0 {
                    self.lastComponentPowerAt = Date()
                }
                if abs(self.cpuPower - component.cpu) > 0.02 { self.cpuPower = component.cpu }
                if abs(self.gpuPower - component.gpu) > 0.02 { self.gpuPower = component.gpu }
                if abs(self.displayPower - display) > 0.02 { self.displayPower = display }
                if abs(self.dramPower - component.dram) > 0.02 { self.dramPower = component.dram }
            }
        }

        // 速率缓存也按墙上时间更新，避免 UI 间隔调大后把计算周期成倍拉长。
        if now.timeIntervalSince(lastRateCalculationAt) >= rateCacheInterval {
            lastRateCalculationAt = now
            let snapshots = DataStore.shared.recentSnapshots(1440)
            // 放电速率只在明确离电时有意义：接电（含满电保持/优化充电暂停）
            // 返回 0，UI 不显示续航预估；历史过滤同样只认 externalConnected == false。
            cachedDrainRate = DrainRateCalculator.drainRate(
                level: currentLevel,
                isOnBattery: !isPluggedIn,
                batteryPower: currentBatteryPower,
                voltage: currentVoltage,
                maxCapacity: currentInfo?.maxCapacity ?? 0,
                healthPercent: systemHealthPercent,
                dischargeStart: dischargeStartTime,
                snapshots: snapshots
            )
            cachedChargeRate = Self.smoothRate(old: cachedChargeRate, measured: DrainRateCalculator.chargeRate(snapshots: snapshots))
        }
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

    /// 速率 EMA 平滑：旧值 0.6 + 新测量 0.4；测量为 0（样本不足）时保持旧值，避免预估时间瞬间变「计算中」或跳变
    private static func smoothRate(old: Double, measured: Double) -> Double {
        guard measured > 0 else { return old }
        guard old > 0 else { return measured }
        return old * 0.6 + measured * 0.4
    }

    private func sampleStorage() {
        let ps = reader.readPowerSource()
        let info = reader.readBatteryInfo()
        let isPluggedIn = info?.externalConnected ?? ps.isPluggedIn

        let snapshot = BatterySnapshot(
            timestamp: Date(),
            level: ps.level,
            isCharging: ps.isCharging,
            wattage: info?.systemPower ?? info?.wattage ?? 0,
            temperature: info?.temperature ?? 0,
            screenOn: !isSleeping && !areScreensSleeping,
            batteryPower: info?.batteryPower ?? 0,
            systemPowerAvailable: info?.systemPowerAvailable ?? false,
            systemPowerIsEstimated: info?.systemPowerIsEstimated ?? false,
            cpuPower: cpuPower,
            gpuPower: gpuPower,
            displayPower: displayPower,
            dramPower: dramPower,
            externalConnected: isPluggedIn
        )
        DataStore.shared.saveSnapshot(snapshot)

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
        }
        helperNeedsUpdate = !installed
    }

    /// 用户手动关闭 Helper：后台卸载 root 守护进程（弹一次管理员密码框），
    /// 停止读取分项功耗并清零数据。
    /// 用户取消密码框时守护进程保留，但 app 停止调用——helper 4.0 起
    /// powermetrics 有 60s 空闲自停，保留亦无持续开销。
    func disableHelperInBackground() async {
        let reader = reader
        await Task.detached(priority: .userInitiated) {
            _ = reader.uninstallHelper()
        }.value
        UserDefaults.standard.set(false, forKey: "BatteryBarHelperEnabled")
        helperEnabled = false
        cpuPower = 0
        gpuPower = 0
        dramPower = 0
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
}
