import Foundation

/// 充放电循环记录
struct ChargeCycle: Codable, Identifiable {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var startLevel: Double
    var endLevel: Double
    var totalEnergy: Double    // 等效百分比
    var averageWattage: Double
    var duration: TimeInterval
    var dirty: Bool

    init(startDate: Date, endDate: Date, startLevel: Double, endLevel: Double, totalEnergy: Double, averageWattage: Double) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = endDate
        self.startLevel = startLevel
        self.endLevel = endLevel
        self.totalEnergy = totalEnergy
        self.averageWattage = averageWattage
        self.duration = endDate.timeIntervalSince(startDate)
        self.dirty = true
    }

    // 自定义解码：对新增字段用 decodeIfPresent 兼容旧数据，避免字段变更导致历史数据不可读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decode(Date.self, forKey: .endDate)
        startLevel = try c.decode(Double.self, forKey: .startLevel)
        endLevel = try c.decode(Double.self, forKey: .endLevel)
        totalEnergy = try c.decodeIfPresent(Double.self, forKey: .totalEnergy) ?? 0
        averageWattage = try c.decodeIfPresent(Double.self, forKey: .averageWattage) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? endDate.timeIntervalSince(startDate)
        // 远程同步过来的 cycle 不应标记为 dirty
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }

    var hoursPerCycle: Double { duration / 3600 }
}
