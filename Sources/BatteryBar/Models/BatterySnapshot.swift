import Foundation

/// 电池采样快照（每 60s 一条）
struct BatterySnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var level: Double          // 0~100
    var isCharging: Bool
    var wattage: Double        // 瓦特
    var temperature: Double    // 摄氏度
    var screenOn: Bool
    var cpuPower: Double       // CPU 功耗 (W)
    var gpuPower: Double       // GPU 功耗 (W)
    var displayPower: Double   // 显示器功耗 (W)
    var dramPower: Double      // 内存功耗 (W)
    var dirty: Bool            // 待同步

    init(timestamp: Date, level: Double, isCharging: Bool, wattage: Double, temperature: Double, screenOn: Bool,
         cpuPower: Double = 0, gpuPower: Double = 0, displayPower: Double = 0, dramPower: Double = 0) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.isCharging = isCharging
        self.wattage = wattage
        self.temperature = temperature
        self.screenOn = screenOn
        self.cpuPower = cpuPower
        self.gpuPower = gpuPower
        self.displayPower = displayPower
        self.dramPower = dramPower
        self.dirty = true
    }

    // 向后兼容旧数据（无组件功率字段时默认 0）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        level = try c.decode(Double.self, forKey: .level)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        wattage = try c.decode(Double.self, forKey: .wattage)
        temperature = try c.decode(Double.self, forKey: .temperature)
        screenOn = try c.decode(Bool.self, forKey: .screenOn)
        cpuPower = try c.decodeIfPresent(Double.self, forKey: .cpuPower) ?? 0
        gpuPower = try c.decodeIfPresent(Double.self, forKey: .gpuPower) ?? 0
        displayPower = try c.decodeIfPresent(Double.self, forKey: .displayPower) ?? 0
        dramPower = try c.decodeIfPresent(Double.self, forKey: .dramPower) ?? 0
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? true
    }

    func toJSON() -> [String: Any] {
        [
            "id": id.uuidString,
            "ts": timestamp.timeIntervalSince1970,
            "level": level,
            "charging": isCharging,
            "watt": wattage,
            "temp": temperature,
            "screen": screenOn,
            "cpu": cpuPower,
            "gpu": gpuPower,
            "disp": displayPower,
            "dram": dramPower,
        ]
    }
}
