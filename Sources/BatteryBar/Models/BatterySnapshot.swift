import Foundation

/// 电池采样快照（每 60s 一条）。
///
/// 功率口径（v2）：
/// - `wattage`：系统负载（瓦特）。接电且无系统遥测时为 0（`systemPowerAvailable == false`），
///   不再用电池充电功率冒充系统负载。
/// - `batteryPower`：电池包充入/放出功率绝对值；方向由 `isCharging` 表达。
///   v1 快照只有 wattage，离电时两者等价。
/// - `systemPowerAvailable` / `systemPowerIsEstimated`：标记 wattage 是否可信及来源。
///   v1 充电快照 available=false，只可作为电池功率参与充电统计，不进入系统负载统计与曲线。
struct BatterySnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var level: Double          // 0~100
    var isCharging: Bool
    var wattage: Double        // 系统负载（瓦特）；v1 数据离电时等于电池功率
    var batteryPower: Double   // 电池包充入/放出功率绝对值（瓦特）
    var systemPowerAvailable: Bool
    var systemPowerIsEstimated: Bool
    var temperature: Double    // 摄氏度
    var screenOn: Bool
    var cpuPower: Double       // CPU 功耗 (W)
    var gpuPower: Double       // GPU 功耗 (W)
    var displayPower: Double   // 显示器功耗 (W，按亮度估算)
    var dramPower: Double      // 内存功耗 (W)
    var dirty: Bool            // 待同步

    init(timestamp: Date, level: Double, isCharging: Bool, wattage: Double, temperature: Double, screenOn: Bool,
         batteryPower: Double? = nil, systemPowerAvailable: Bool? = nil, systemPowerIsEstimated: Bool? = nil,
         cpuPower: Double = 0, gpuPower: Double = 0, displayPower: Double = 0, dramPower: Double = 0) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.isCharging = isCharging
        self.wattage = wattage
        // 未显式给出口径时按 v1 规则推导：接电/充电中的 wattage 只是电池包净功率，
        // 不能作为系统负载参与统计（与 init(from:) 的旧数据兼容逻辑保持一致）。
        self.batteryPower = batteryPower ?? wattage
        self.systemPowerAvailable = systemPowerAvailable ?? !isCharging
        self.systemPowerIsEstimated = systemPowerIsEstimated ?? true
        self.temperature = temperature
        self.screenOn = screenOn
        self.cpuPower = cpuPower
        self.gpuPower = gpuPower
        self.displayPower = displayPower
        self.dramPower = dramPower
        self.dirty = true
    }

    // 自定义解码：新增字段用 decodeIfPresent 兼容 v1 历史数据
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        level = try c.decode(Double.self, forKey: .level)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        wattage = try c.decode(Double.self, forKey: .wattage)
        // v1 快照只有 wattage。旧版在离电时它可近似系统负载（估算）；插电/充电时
        // 它只是电池包净功率，不能再冒充系统总功耗。
        batteryPower = try c.decodeIfPresent(Double.self, forKey: .batteryPower) ?? wattage
        systemPowerAvailable = try c.decodeIfPresent(Bool.self, forKey: .systemPowerAvailable) ?? !isCharging
        systemPowerIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .systemPowerIsEstimated) ?? true
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
        case systemPowerAvailable, systemPowerIsEstimated
        case temperature, screenOn, cpuPower, gpuPower, displayPower, dramPower, dirty
    }

    /// 系统负载（瓦特）。不可用时返回 nil——调用方据此把该点排除出系统负载
    /// 统计与曲线，而不是画成 0W 制造假谷底。
    var systemLoad: Double? {
        systemPowerAvailable ? wattage : nil
    }

    /// WebDAV JSONL 行格式（扁平字典）。上传用 toJSON，下载用 from(remoteJSON:)；
    /// 两端字段必须同步演进并保持对远端旧格式的兼容。
    func toJSON() -> [String: Any] {
        [
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
            dramPower: dict["dram"] as? Double ?? 0
        )
        snap.id = id
        snap.dirty = false
        return snap
    }
}
