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
/// - v3：+ `externalConnected`（本结构）。**字段存在与否即可靠区分新旧格式**；
///   nil 表示旧数据来源未知，不得推断。
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
    var dirty: Bool            // 待同步

    init(timestamp: Date, level: Double, isCharging: Bool, wattage: Double, temperature: Double, screenOn: Bool,
         batteryPower: Double? = nil, systemPowerAvailable: Bool? = nil, systemPowerIsEstimated: Bool? = nil,
         cpuPower: Double = 0, gpuPower: Double = 0, displayPower: Double = 0, dramPower: Double = 0,
         externalConnected: Bool? = nil) {
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
        try c.encode(dirty, forKey: .dirty)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, level, isCharging, wattage, batteryPower
        case systemPowerAvailable, systemPowerIsEstimated, externalConnected
        case temperature, screenOn, cpuPower, gpuPower, displayPower, dramPower, dirty
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
            externalConnected: dict["ext"] as? Bool
        )
        snap.id = id
        snap.dirty = false
        return snap
    }
}
