import Foundation

final class PowerSampler: ObservableObject, @unchecked Sendable {
    private let reader = BatteryReader()
    private let cycleTracker = CycleTracker()
    private let sleepWatcher = SleepWatcher()
    private var dispatchTimer: DispatchSourceTimer?
    private var storageTimer: Timer?
    private var refreshObserver: NSObjectProtocol?
    private var staticInfoObserver: NSObjectProtocol?

    @Published var currentLevel: Double = 0
    @Published var currentIsCharging: Bool = false
    @Published var currentWattage: Double = 0
    @Published var currentTemperature: Double = 0
    @Published var currentVoltage: Double = 0
    @Published var currentAmperage: Double = 0
    @Published var currentInfo: BatteryInfo?
    @Published var systemHealthPercent: Double = 100
    @Published var lastUpdateTime: Date = Date()
    @Published var tick: Bool = false

    @Published var cpuPower: Double = 0
    @Published var gpuPower: Double = 0
    @Published var displayPower: Double = 0
    @Published var dramPower: Double = 0

    @Published var helperNeedsUpdate: Bool = false

    // 放电/充电速率缓存：每 30 个 UI tick 重算一次，避免 View body 每 tick 全量扫描 DataStore
    @Published var cachedDrainRate: Double = 0
    @Published var cachedChargeRate: Double = 0
    private var rateCacheTick: Int = 0
    private let rateCacheInterval: Int = 30

    /// Helper 服务开关（默认关闭，用户在 PowerTab 手动开启）
    /// 开启后才会安装 helper 并读取 CPU/GPU 分项功耗
    var helperEnabled: Bool {
        UserDefaults.standard.object(forKey: "BatteryBarHelperEnabled") as? Bool ?? false
    }

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
    private var componentPowerTick: Int = 0  // 独立计数器，避免依赖 Unix 时间戳取模导致采样周期不可控
    private var isSleeping: Bool = false
    private var sleepStartTime: Date?
    private var isStarted: Bool = false
    var uiInterval: TimeInterval = 1

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
        sleepWatcher.onSleep = { [weak self] in
            self?.handleSleep()
        }
        sleepWatcher.onWake = { [weak self] in
            self?.handleWake()
        }
        sleepWatcher.start()

        // 观察刷新间隔变更通知（object 为 Double）
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .init("RefreshIntervalChanged"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let interval = note.object as? Double {
                self?.uiInterval = interval
                self?.restartTimer()
            }
        }

        sampleUI()
        sampleStorage()

        // 后台读取系统健康度
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let health = self?.reader.readSystemHealthPercent() ?? 100
            DispatchQueue.main.async { self?.systemHealthPercent = health }
        }

        // 后台预加载静态信息（机器型号、序列号、制造商），避免主线程每秒 spawn system_profiler
        // 加载完成后通过 PowerSamplerDidUpdate 通知触发 UI 刷新
        reader.prefetchStaticInfo()
        staticInfoObserver = NotificationCenter.default.addObserver(
            forName: .init("BatteryReaderStaticInfoLoaded"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
            NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)
        }

        // Helper 服务：仅在用户开启时检查/安装
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard self?.helperEnabled == true else { return }
            if self?.reader.needsHelperUpdate() == true {
                let installed = self?.reader.installHelperIfNeeded() ?? false
                DispatchQueue.main.async {
                    self?.helperNeedsUpdate = !installed
                    self?.objectWillChange.send()
                }
            }
        }

        // 存储定时器
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
        if let obs = staticInfoObserver {
            NotificationCenter.default.removeObserver(obs)
            staticInfoObserver = nil
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
        timer.schedule(deadline: .now(), repeating: uiInterval)
        timer.setEventHandler { [weak self] in
            self?.sampleUI()
        }
        timer.resume()
        dispatchTimer = timer
    }

    // MARK: - Sleep / Wake

    private func handleSleep() {
        isSleeping = true
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

        objectWillChange.send()

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

        currentLevel = ps.level
        currentIsCharging = ps.isCharging
        currentWattage = info?.systemPower ?? info?.wattage ?? 0
        currentTemperature = info?.temperature ?? 0
        currentVoltage = info?.voltage ?? 0
        currentAmperage = info?.instantAmperage ?? 0
        currentInfo = info
        lastUpdateTime = Date()
        tick.toggle()

        // 通知状态栏 AppDelegate 刷新 button.title（title 不自动响应 @Published）
        NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)

        // 检查通知
        NotificationManager.shared.checkLowBattery(level: currentLevel, isCharging: currentIsCharging)
        if previousCharging && !currentIsCharging && currentLevel >= 100 {
            NotificationManager.shared.checkFullCharge(level: currentLevel, wasCharging: true)
        }

        // 每 10 个 UI tick 读取一次分项功耗（仅在 Helper 开启时）
        // 用计数器而非时间戳取模，避免 uiInterval 非 1s 时采样周期不可控
        componentPowerTick += 1
        if helperEnabled && componentPowerTick % 10 == 0 {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let componentPower = self?.reader.readComponentPower() ?? ComponentPower(cpu: 0, gpu: 0, display: 0, other: 0, dram: 0)
                let displayPower = self?.reader.estimateDisplayPower() ?? 0
                DispatchQueue.main.async {
                    self?.cpuPower = componentPower.cpu
                    self?.gpuPower = componentPower.gpu
                    self?.displayPower = displayPower
                    self?.dramPower = componentPower.dram
                }
            }
        }

        // 每 rateCacheInterval 个 tick 重算一次放电/充电速率（DrainRateCalculator 内部会扫描 DataStore）
        // 节流避免每 tick 全量扫描，View 直接读取 cachedDrainRate / cachedChargeRate
        rateCacheTick += 1
        if rateCacheTick % rateCacheInterval == 0 {
            cachedDrainRate = DrainRateCalculator.drainRate(
                level: currentLevel,
                isCharging: currentIsCharging,
                wattage: currentWattage,
                voltage: currentVoltage,
                maxCapacity: currentInfo?.maxCapacity ?? 0,
                healthPercent: systemHealthPercent,
                dischargeStart: dischargeStartTime
            )
            cachedChargeRate = Self.smoothRate(old: cachedChargeRate, measured: DrainRateCalculator.chargeRate())
        }
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
            screenOn: !isSleeping,
            cpuPower: cpuPower,
            gpuPower: gpuPower,
            displayPower: displayPower,
            dramPower: dramPower
        )
        DataStore.shared.saveSnapshot(snapshot)

        // 只在离电时累加使用时间
        // awake 计入屏幕亮起；睡眠期间 Timer 不触发，实际睡眠时长由 onWake 补足
        if !isPluggedIn {
            if isSleeping {
                currentDischargeSleep += 1
            } else {
                currentDischargeScreenOn += 1
            }
        }

        cycleTracker.update(isCharging: ps.isCharging, level: ps.level, wattage: info?.systemPower ?? info?.wattage ?? 0)

        // 每 5 分钟落盘一次
        saveTick += 1
        if saveTick % 5 == 0 {
            persistUsageState()
        }
    }

    func openBatterySettings() {
        reader.openBatterySettings()
    }

    /// 用户手动开启 Helper：触发安装（会弹一次管理员密码框）
    /// 仅当安装成功后才写入 UserDefaults，避免密码取消/错误时开关仍显示开启
    @discardableResult
    func enableHelper() -> Bool {
        let installed = reader.installHelperIfNeeded()
        if installed {
            UserDefaults.standard.set(true, forKey: "BatteryBarHelperEnabled")
        }
        DispatchQueue.main.async {
            self.helperNeedsUpdate = !installed
            self.objectWillChange.send()
        }
        return installed
    }

    /// 用户手动关闭 Helper：停止读取分项功耗，清零数据
    func disableHelper() {
        UserDefaults.standard.set(false, forKey: "BatteryBarHelperEnabled")
        objectWillChange.send()
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
}
