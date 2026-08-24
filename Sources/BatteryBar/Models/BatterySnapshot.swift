import Foundation

/// 电池采样快照（每 60s 一条）。
///
/// 功率口径：
/// - `wattage`：系统负载（瓦特）。接电且无系统遥测时为 0（`systemPowerAvailable == false`）。
/// - `batteryPower`：电池包充入/放出功率绝对值；方向由 `isCharging` 表达。
/// - `isCharging` 只表达电池包是否正在充入。macOS 的满电保持、优化充电暂停、
///   80% 上限都会出现 externalConnected=true 且 isCharging=false 的长时间状态，
///   禁止把 `!isCharging` 当作"离电"。
///
/// 电源来源与 schema 演进（provenance）：
/// - v1：只有 wattage（离电≈电池功率，接电=电池充电功率）。
/// - v2：+ batteryPower/systemPowerAvailable/systemPowerIsEstimated，无电源来源字段。
/// - v3：+ `externalConnected`。**字段存在与否即可靠区分新旧格式**；
///   nil 表示旧数据来源未知，不得推断。
/// - v4：+ `lowPowerModeEnabled` / `thermalState`；均为可选解释字段，不改变旧点可信度。
/// - v5：+ 分钟聚合与亮度观测，全部可选、`encodeIfPresent`：
///   自然分钟窗口的能量/平均/峰值/覆盖率、充放分开的电池能量、
///   时长加权温度均值与最大值、离散状态份额、窗口最高热压力，
///   以及显示器原始亮度（不再制造显示器瓦数）。
///   旧端缺键保持 nil，不推导伪数据。
struct BatterySnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var level: Double          // 0~100
    var isCharging: Bool       // 仅表示电池包正在充入
    var wattage: Double        // 系统负载（瓦特）；旧数据口径见 struct 注释
    var batteryPower: Double   // 电池包充入/放出功率绝对值（瓦特）
    var systemPowerAvailable: Bool
    var systemPowerIsEstimated: Bool
    /// 是否接外接电源。nil = 旧格式数据未知；禁止用 !isCharging 回填推断。
    var externalConnected: Bool?
    var temperature: Double    // 摄氏度
    var screenOn: Bool
    var cpuPower: Double       // CPU 功耗 (W)
    var gpuPower: Double       // GPU 功耗 (W)
    var displayPower: Double   // 显示器功耗 (W，按亮度估算)
    var dramPower: Double      // 内存功耗 (W)
    /// 公开 Foundation 状态，用来解释同负载下的性能/功耗变化；nil 表示旧 schema 未记录。
    var lowPowerModeEnabled: Bool?
    var thermalState: String?
    // MARK: v5 分钟聚合（全部可选；nil = 无达标聚合或旧格式数据）
    /// 聚合所属自然分钟窗口起点
    var aggregateWindowStart: Date?
    var systemEnergyWh: Double?
    var systemPowerAverage: Double?
    var systemPowerPeak: Double?
    var systemCoverage: Double?
    var batteryChargeWh: Double?
    var batteryDischargeWh: Double?
    /// 按有效时长加权的温度均值（非样本算术平均）
    var temperatureAverage: Double?
    var temperatureMaximum: Double?
    var temperatureCoverage: Double?
    var screenOnFraction: Double?
    var lowPowerModeFraction: Double?
    /// 窗口内观察到的最高热压力等级标签
    var maximumThermalState: String?
    /// 显示器原始亮度 0...1；nil = 不可读取或旧格式
    var displayBrightness: Double?
    var brightnessAvailable: Bool?
    var brightnessReadAt: Date?
    var dirty: Bool            // 待同步

    init(timestamp: Date, level: Double, isCharging: Bool, wattage: Double, temperature: Double, screenOn: Bool,
         batteryPower: Double? = nil, systemPowerAvailable: Bool? = nil, systemPowerIsEstimated: Bool? = nil,
         cpuPower: Double = 0, gpuPower: Double = 0, displayPower: Double = 0, dramPower: Double = 0,
         externalConnected: Bool? = nil, lowPowerModeEnabled: Bool? = nil, thermalState: String? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.isCharging = isCharging
        self.wattage = wattage
        self.batteryPower = batteryPower ?? wattage
        self.systemPowerAvailable = systemPowerAvailable ?? !isCharging
        self.systemPowerIsEstimated = systemPowerIsEstimated ?? true
        self.externalConnected = externalConnected
        self.temperature = temperature
        self.screenOn = screenOn
        self.cpuPower = cpuPower
        self.gpuPower = gpuPower
        self.displayPower = displayPower
        self.dramPower = dramPower
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.dirty = true
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        level = try c.decode(Double.self, forKey: .level)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        wattage = try c.decode(Double.self, forKey: .wattage)
        batteryPower = try c.decodeIfPresent(Double.self, forKey: .batteryPower) ?? wattage
        systemPowerAvailable = try c.decodeIfPresent(Bool.self, forKey: .systemPowerAvailable) ?? !isCharging
        systemPowerIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .systemPowerIsEstimated) ?? true
        externalConnected = try c.decodeIfPresent(Bool.self, forKey: .externalConnected)
        temperature = try c.decode(Double.self, forKey: .temperature)
        screenOn = try c.decode(Bool.self, forKey: .screenOn)
        cpuPower = try c.decodeIfPresent(Double.self, forKey: .cpuPower) ?? 0
        gpuPower = try c.decodeIfPresent(Double.self, forKey: .gpuPower) ?? 0
        displayPower = try c.decodeIfPresent(Double.self, forKey: .displayPower) ?? 0
        dramPower = try c.decodeIfPresent(Double.self, forKey: .dramPower) ?? 0
        lowPowerModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .lowPowerModeEnabled)
        thermalState = try c.decodeIfPresent(String.self, forKey: .thermalState)
        aggregateWindowStart = try c.decodeIfPresent(Date.self, forKey: .aggregateWindowStart)
        systemEnergyWh = try c.decodeIfPresent(Double.self, forKey: .systemEnergyWh)
        systemPowerAverage = try c.decodeIfPresent(Double.self, forKey: .systemPowerAverage)
        systemPowerPeak = try c.decodeIfPresent(Double.self, forKey: .systemPowerPeak)
        systemCoverage = try c.decodeIfPresent(Double.self, forKey: .systemCoverage)
        batteryChargeWh = try c.decodeIfPresent(Double.self, forKey: .batteryChargeWh)
        batteryDischargeWh = try c.decodeIfPresent(Double.self, forKey: .batteryDischargeWh)
        temperatureAverage = try c.decodeIfPresent(Double.self, forKey: .temperatureAverage)
        temperatureMaximum = try c.decodeIfPresent(Double.self, forKey: .temperatureMaximum)
        temperatureCoverage = try c.decodeIfPresent(Double.self, forKey: .temperatureCoverage)
        screenOnFraction = try c.decodeIfPresent(Double.self, forKey: .screenOnFraction)
        lowPowerModeFraction = try c.decodeIfPresent(Double.self, forKey: .lowPowerModeFraction)
        maximumThermalState = try c.decodeIfPresent(String.self, forKey: .maximumThermalState)
        displayBrightness = try c.decodeIfPresent(Double.self, forKey: .displayBrightness)
        brightnessAvailable = try c.decodeIfPresent(Bool.self, forKey: .brightnessAvailable)
        brightnessReadAt = try c.decodeIfPresent(Date.self, forKey: .brightnessReadAt)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(level, forKey: .level)
        try c.encode(isCharging, forKey: .isCharging)
        try c.encode(wattage, forKey: .wattage)
        try c.encode(batteryPower, forKey: .batteryPower)
        try c.encode(systemPowerAvailable, forKey: .systemPowerAvailable)
        try c.encode(systemPowerIsEstimated, forKey: .systemPowerIsEstimated)
        // encodeIfPresent：键缺失即代表 v1/v2 来源未知，不伪造电源状态
        try c.encodeIfPresent(externalConnected, forKey: .externalConnected)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(screenOn, forKey: .screenOn)
        try c.encode(cpuPower, forKey: .cpuPower)
        try c.encode(gpuPower, forKey: .gpuPower)
        try c.encode(displayPower, forKey: .displayPower)
        try c.encode(dramPower, forKey: .dramPower)
        try c.encodeIfPresent(lowPowerModeEnabled, forKey: .lowPowerModeEnabled)
        try c.encodeIfPresent(thermalState, forKey: .thermalState)
        try c.encodeIfPresent(aggregateWindowStart, forKey: .aggregateWindowStart)
        try c.encodeIfPresent(systemEnergyWh, forKey: .systemEnergyWh)
        try c.encodeIfPresent(systemPowerAverage, forKey: .systemPowerAverage)
        try c.encodeIfPresent(systemPowerPeak, forKey: .systemPowerPeak)
        try c.encodeIfPresent(systemCoverage, forKey: .systemCoverage)
        try c.encodeIfPresent(batteryChargeWh, forKey: .batteryChargeWh)
        try c.encodeIfPresent(batteryDischargeWh, forKey: .batteryDischargeWh)
        try c.encodeIfPresent(temperatureAverage, forKey: .temperatureAverage)
        try c.encodeIfPresent(temperatureMaximum, forKey: .temperatureMaximum)
        try c.encodeIfPresent(temperatureCoverage, forKey: .temperatureCoverage)
        try c.encodeIfPresent(screenOnFraction, forKey: .screenOnFraction)
        try c.encodeIfPresent(lowPowerModeFraction, forKey: .lowPowerModeFraction)
        try c.encodeIfPresent(maximumThermalState, forKey: .maximumThermalState)
        try c.encodeIfPresent(displayBrightness, forKey: .displayBrightness)
        try c.encodeIfPresent(brightnessAvailable, forKey: .brightnessAvailable)
        try c.encodeIfPresent(brightnessReadAt, forKey: .brightnessReadAt)
        try c.encode(dirty, forKey: .dirty)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, level, isCharging, wattage, batteryPower
        case systemPowerAvailable, systemPowerIsEstimated, externalConnected
        case temperature, screenOn, cpuPower, gpuPower, displayPower, dramPower
        case lowPowerModeEnabled, thermalState, dirty
        case aggregateWindowStart, systemEnergyWh, systemPowerAverage, systemPowerPeak
        case systemCoverage, batteryChargeWh, batteryDischargeWh
        case temperatureAverage, temperatureMaximum, temperatureCoverage
        case screenOnFraction, lowPowerModeFraction, maximumThermalState
        case displayBrightness, brightnessAvailable, brightnessReadAt
    }

    /// 可信的系统负载。
    /// 实测遥测（estimated == false）独立可信，无论电源状态如何都保留；
    /// 估算负载只有在**明确离电**时才可信——来源未知的估算点可能是
    /// "接电未充电"被误标的历史污染（满电/优化充电暂停/80% 上限），保守排除。
    var trustedSystemLoad: Double? {
        guard systemPowerAvailable, wattage > 0 else { return nil }
        if !systemPowerIsEstimated { return wattage }
        return externalConnected == false ? wattage : nil
    }

    /// 明确离电（externalConnected 显式 false）。旧数据一律不算离电。
    var isDefinitelyOnBattery: Bool { externalConnected == false }

    /// 把一个已完成分钟窗口的聚合写入 v5 字段。
    /// 覆盖率未达标的量保持 nil（不伪造完整分钟指标）；
    /// 温度最大值在覆盖率不足时仍保留，由 temperatureCoverage 附带说明。
    mutating func apply(
        minuteAggregate aggregate: MinuteAggregate,
        displayBrightness brightness: Double?,
        brightnessAvailable: Bool,
        brightnessReadAt: Date?
    ) {
        aggregateWindowStart = aggregate.windowStart
        systemEnergyWh = aggregate.hasFullSystemMetric ? aggregate.systemEnergyWh : nil
        systemPowerAverage = aggregate.hasFullSystemMetric ? aggregate.systemPowerAverage : nil
        systemPowerPeak = aggregate.hasFullSystemMetric ? aggregate.systemPowerPeak : nil
        systemCoverage = aggregate.systemCoverage
        batteryChargeWh = aggregate.batteryChargeWh
        batteryDischargeWh = aggregate.batteryDischargeWh
        // 温度均值/最大值跟随趋势可用性（coverage ≥ 0.5）；覆盖率始终如实记录
        if aggregate.hasUsableTemperatureTrend {
            temperatureAverage = aggregate.temperatureAverage
            temperatureMaximum = aggregate.temperatureMaximum
        } else {
            temperatureAverage = nil
            temperatureMaximum = nil
        }
        temperatureCoverage = aggregate.temperatureCoverage
        screenOnFraction = aggregate.screenOnFraction
        lowPowerModeFraction = aggregate.lowPowerModeFraction
        maximumThermalState = aggregate.maximumThermalStateLabel
        self.displayBrightness = brightness
        self.brightnessAvailable = brightnessAvailable
        self.brightnessReadAt = brightnessReadAt
    }

    /// WebDAV JSONL 行格式（扁平字典）。`ext` 仅在已知时写出，
    /// 缺失即代表旧格式，下载端不得推断。
    func toJSON() -> [String: Any] {
        var json: [String: Any] = [
            "id": id.uuidString,
            "ts": timestamp.timeIntervalSince1970,
            "level": level,
            "charging": isCharging,
            "watt": wattage,
            "batteryWatt": batteryPower,
            "powerAvailable": systemPowerAvailable,
            "powerEstimated": systemPowerIsEstimated,
            "temp": temperature,
            "screen": screenOn,
            "cpu": cpuPower,
            "gpu": gpuPower,
            "disp": displayPower,
            "dram": dramPower,
        ]
        if let externalConnected {
            json["ext"] = externalConnected
        }
        if let lowPowerModeEnabled { json["lpm"] = lowPowerModeEnabled }
        if let thermalState { json["thermal"] = thermalState }
        // v5 聚合：仅在已知时写出，缺键即旧格式
        if let aggregateWindowStart { json["aggWin"] = aggregateWindowStart.timeIntervalSince1970 }
        if let systemEnergyWh { json["sysEWh"] = systemEnergyWh }
        if let systemPowerAverage { json["sysPAvg"] = systemPowerAverage }
        if let systemPowerPeak { json["sysPPeak"] = systemPowerPeak }
        if let systemCoverage { json["sysCov"] = systemCoverage }
        if let batteryChargeWh { json["batChgWh"] = batteryChargeWh }
        if let batteryDischargeWh { json["batDisWh"] = batteryDischargeWh }
        if let temperatureAverage { json["tAvg"] = temperatureAverage }
        if let temperatureMaximum { json["tMax"] = temperatureMaximum }
        if let temperatureCoverage { json["tCov"] = temperatureCoverage }
        if let screenOnFraction { json["screenFrac"] = screenOnFraction }
        if let lowPowerModeFraction { json["lpmFrac"] = lowPowerModeFraction }
        if let maximumThermalState { json["thermalPeak"] = maximumThermalState }
        if let displayBrightness { json["bright"] = displayBrightness }
        if let brightnessAvailable { json["brightOK"] = brightnessAvailable }
        if let brightnessReadAt { json["brightAt"] = brightnessReadAt.timeIntervalSince1970 }
        return json
    }

    static func from(remoteJSON dict: [String: Any]) -> BatterySnapshot? {
        guard let idStr = dict["id"] as? String,
              let id = UUID(uuidString: idStr),
              let ts = dict["ts"] as? Double
        else { return nil }

        let isCharging = dict["charging"] as? Bool ?? false
        let wattage = dict["watt"] as? Double ?? 0
        var snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: ts),
            level: dict["level"] as? Double ?? 0,
            isCharging: isCharging,
            wattage: wattage,
            temperature: dict["temp"] as? Double ?? 0,
            screenOn: dict["screen"] as? Bool ?? false,
            batteryPower: dict["batteryWatt"] as? Double,
            systemPowerAvailable: dict["powerAvailable"] as? Bool,
            systemPowerIsEstimated: dict["powerEstimated"] as? Bool,
            cpuPower: dict["cpu"] as? Double ?? 0,
            gpuPower: dict["gpu"] as? Double ?? 0,
            displayPower: dict["disp"] as? Double ?? 0,
            dramPower: dict["dram"] as? Double ?? 0,
            externalConnected: dict["ext"] as? Bool,
            lowPowerModeEnabled: dict["lpm"] as? Bool,
            thermalState: dict["thermal"] as? String
        )
        snap.id = id
        // v5 聚合字段：远端缺键保持 nil，不推导伪数据
        if let aggWin = dict["aggWin"] as? Double { snap.aggregateWindowStart = Date(timeIntervalSince1970: aggWin) }
        snap.systemEnergyWh = dict["sysEWh"] as? Double
        snap.systemPowerAverage = dict["sysPAvg"] as? Double
        snap.systemPowerPeak = dict["sysPPeak"] as? Double
        snap.systemCoverage = dict["sysCov"] as? Double
        snap.batteryChargeWh = dict["batChgWh"] as? Double
        snap.batteryDischargeWh = dict["batDisWh"] as? Double
        snap.temperatureAverage = dict["tAvg"] as? Double
        snap.temperatureMaximum = dict["tMax"] as? Double
        snap.temperatureCoverage = dict["tCov"] as? Double
        snap.screenOnFraction = dict["screenFrac"] as? Double
        snap.lowPowerModeFraction = dict["lpmFrac"] as? Double
        snap.maximumThermalState = dict["thermalPeak"] as? String
        snap.displayBrightness = dict["bright"] as? Double
        snap.brightnessAvailable = dict["brightOK"] as? Bool
        if let brightAt = dict["brightAt"] as? Double { snap.brightnessReadAt = Date(timeIntervalSince1970: brightAt) }
        snap.dirty = false
        return snap
    }
}
