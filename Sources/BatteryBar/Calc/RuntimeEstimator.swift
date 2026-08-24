import Foundation

/// 续航/充电估算结果。证据不足时调用方得到 nil（或带 failureReason 的失败态），
/// 不得用机型经验表填补数字。
struct EstimationResult: Equatable {
    enum Basis: String, Equatable {
        /// IOPowerSources 系统剩余时间（不透明值，独立展示，永不静默混算）
        case systemReported
        /// 历史电量斜率（Theil–Sen）
        case historicalSlope
        /// 电池功率证据（放电 Wh / 有效时长 ÷ 满充能量）
        case batteryPower
        /// 多路证据按置信度加权
        case fused
    }

    /// 置信度 0...1；band 是它的离散展示映射
    var confidence: Double
    var basis: Basis
    /// 剩余时间（小时）或充满时间（小时）
    var valueHours: Double
    /// 速率（%/h），续航为正放电速率，充电为正充电速率
    var ratePercentPerHour: Double
    /// 证据时长（秒）
    var evidenceDuration: TimeInterval
    /// 证据窗口覆盖率 0...1
    var coverage: Double
    var lowerHours: Double?
    var upperHours: Double?
    /// 失败原因仅在不可用时有意义
    var failureReason: String?

    var band: ConfidenceBand {
        ConfidenceBand.of(confidence)
    }

    static func == (lhs: EstimationResult, rhs: EstimationResult) -> Bool {
        lhs.basis == rhs.basis
            && lhs.valueHours == rhs.valueHours
            && lhs.ratePercentPerHour == rhs.ratePercentPerHour
            && lhs.confidence == rhs.confidence
            && lhs.evidenceDuration == rhs.evidenceDuration
            && lhs.coverage == rhs.coverage
    }
}

extension EstimationResult {
    /// 结果来源的中文标注（UI 必须随估算一起展示）
    var basisDisplayName: String {
        switch basis {
        case .systemReported: "系统估算"
        case .historicalSlope: "历史趋势"
        case .batteryPower: "功率估算"
        case .fused: "融合"
        }
    }
}

enum ConfidenceBand: String, Equatable {
    case low, medium, high

    static func of(_ confidence: Double) -> ConfidenceBand {
        if confidence >= 0.7 { return .high }
        if confidence >= 0.4 { return .medium }
        return .low
    }

    var displayName: String {
        switch self {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        }
    }
}

/// 运行时续航与充电估算（纯逻辑、时间注入、输入有界）。
///
/// 冻结口径：
/// - 移除 machineBaselineDrainRate、默认 11.1V、固定 6W/9W 机型功耗与
///   “证据不足仍给数字”的路径——证据不足必须返回“正在校准/数据不足”。
/// - 历史百分比斜率：仅明确离电且来源明确的最近 60 分钟；跨度 ≥20 分钟、
///   净下降 ≥2%、覆盖率 ≥0.7；对间隔 ≥5 分钟的点对取 (levelStart-levelEnd)/hours，
///   Theil–Sen 中位斜率抗量化回跳与异常点；中位斜率 ≤0 不可用；
///   historyConfidence = min(跨度/60min, 净下降/5%, 覆盖率) 裁到 0...1。
/// - 电池功率证据：最近 15 分钟 batteryDischargeWh ÷ 有效时长；fullEnergyWh 仅在
///   FullChargeCapacity 与合理电压均真实可用时按 capacityAh×voltageV 计算，
///   禁止默认电压；合理性检查只用于拒绝坏数据，不静默夹值；
///   当前电压只能提供中等置信度（上限 0.66）。
/// - 融合：两路都有效时按各自 confidence 加权速率；速率相差 >2 倍时总置信度
///   打 0.6 折并扩大区间；总置信度 <0.4 不显示 App 估算。
/// - 充电估算：仅 isCharging 且 externalConnected；最近 30 分钟 Theil–Sen 正斜率，
///   跨度 ≥5 分钟且净增长 ≥1%；>80% 因涓流/优化充电降置信度；暂停/满电保持/
///   上限无正增长不显示；异常速率直接拒绝，不再用 3–80%/h 夹值制造结果。
enum RuntimeEstimator {

    /// 展示门槛（冻结）：最终 confidence 低于该值的结果一律返回 nil，
    /// 内部证据可以低置信存在，但不得到达 UI。
    static let minimumDisplayConfidence = 0.40
    /// 两路速率差异超过该倍数视为互相矛盾
    static let contradictionRatio = 2.0

    /// 单路/融合出口统一执行展示门槛：低于门槛视为数据不足。
    private static func gated(_ result: EstimationResult?) -> EstimationResult? {
        guard let result, result.confidence >= minimumDisplayConfidence else { return nil }
        return result
    }

    struct Inputs {
        var now = Date()
        var currentLevel: Double = 0
        var isCharging = false
        /// nil 视同来源未知（不显示任何估算）
        var externalConnected: Bool?
        /// 最近快照（调用方负责有界，建议 ≤120 条）
        var snapshots: [BatterySnapshot] = []
        /// 最近完成的分钟聚合，升序（调用方负责有界，建议 ≤120 个）
        var minuteAggregates: [MinuteAggregate] = []
        /// 实际满充容量 mAh；0 = 未知
        var fullChargeCapacityMah: Int = 0
        /// 当前电压 mV；0 = 未知
        var voltageMV: Double = 0
        /// IOPS 系统剩余时间（分钟）；-1 = 不可用
        var systemReportedMinutes: Int = -1
    }

    // MARK: - 离电续航

    /// 离电续航估算。返回 nil = 数据不足（正在校准）。
    /// systemReported 回退由 `systemReportedEstimate` 单独提供，调用方必须标注来源。
    static func dischargeEstimate(_ input: Inputs) -> EstimationResult? {
        guard input.externalConnected == false, !input.isCharging else { return nil }
        guard input.currentLevel > 0 else { return nil }

        let slope = historicalSlopeEvidence(input)
        let power = batteryPowerEvidence(input)

        switch (slope, power) {
        case let (.some(a), .some(b)):
            let totalWeight = a.confidence + b.confidence
            guard totalWeight > 0 else { return nil }
            let fusedRate = (a.ratePercentPerHour * a.confidence + b.ratePercentPerHour * b.confidence) / totalWeight
            guard fusedRate > 0 else { return nil }
            let ratio = max(a.ratePercentPerHour, b.ratePercentPerHour) / max(1e-9, min(a.ratePercentPerHour, b.ratePercentPerHour))
            let contradicted = ratio > contradictionRatio
            var confidence = ((a.confidence + b.confidence) / 2) * (contradicted ? 0.6 : 1)
            confidence = min(1, confidence)
            // 融合出口同样执行展示门槛：矛盾惩罚后低于门槛即数据不足
            guard confidence >= minimumDisplayConfidence else { return nil }
            let spread = max(
                abs(a.ratePercentPerHour - b.ratePercentPerHour) / fusedRate,
                contradicted ? 0.35 : 0.15
            )
            return EstimationResult(
                confidence: confidence,
                basis: .fused,
                valueHours: input.currentLevel / fusedRate,
                ratePercentPerHour: fusedRate,
                evidenceDuration: max(a.evidenceDuration, b.evidenceDuration),
                coverage: min(a.coverage, b.coverage),
                lowerHours: max(0, input.currentLevel / (fusedRate * (1 + spread))),
                upperHours: input.currentLevel / max(1e-9, fusedRate * max(0.05, 1 - spread)),
                failureReason: contradicted ? "两路证据差异较大" : nil
            )
        case let (.some(a), .none):
            return gated(single(a, level: input.currentLevel))
        case let (.none, .some(b)):
            return gated(single(b, level: input.currentLevel))
        case (.none, .none):
            return nil
        }
    }

    private static func single(_ evidence: EstimationResult, level: Double) -> EstimationResult? {
        guard evidence.ratePercentPerHour > 0 else { return nil }
        var result = evidence
        result.valueHours = level / evidence.ratePercentPerHour
        return result
    }

    /// A. 历史百分比斜率证据。rate 即 %/h；valueHours 由调用方按当前电量折算。
    static func historicalSlopeEvidence(_ input: Inputs) -> EstimationResult? {
        let windowStart = input.now.addingTimeInterval(-3600)
        let points = input.snapshots
            .filter { $0.timestamp >= windowStart && $0.timestamp <= input.now }
            .filter { $0.externalConnected == false }               // 仅明确离电且来源明确
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.level) }
        guard points.count >= 2,
              let span = interval(points.first!.0, points.last!.0),
              span >= 20 * 60
        else { return nil }

        let netDrop = points.first!.1 - points.last!.1
        guard netDrop >= 2 else { return nil }

        let coverage = coveredFraction(points: points, span: span)
        guard coverage >= 0.7 else { return nil }

        let slopes = pairwiseSlopes(points: points, minimumPairInterval: 5 * 60)
        guard let median = median(of: slopes), median > 0 else { return nil }

        let confidence = clamp01(min(span / 3600, netDrop / 5, coverage))
        return EstimationResult(
            confidence: confidence,
            basis: .historicalSlope,
            valueHours: 0,                                      // 由融合/单路出口折算
            ratePercentPerHour: median,
            evidenceDuration: span,
            coverage: coverage
        )
    }

    /// B. 电池功率证据。使用最近 15 分钟聚合的放出能量与有效时长。
    static func batteryPowerEvidence(_ input: Inputs) -> EstimationResult? {
        let windowStart = input.now.addingTimeInterval(-15 * 60)
        let recent = input.minuteAggregates.filter { $0.windowStart >= windowStart && $0.windowStart <= input.now }
        guard !recent.isEmpty else { return nil }

        let dischargeWh = recent.reduce(0) { $0 + $1.batteryDischargeWh }
        let seconds = recent.reduce(0) { $0 + $1.batteryDischargeSeconds }
        let coverage = clamp01(seconds / (15 * 60))
        // 有效时长不足 10 分钟：证据太薄，宁可校准
        guard seconds >= 600, dischargeWh > 0 else { return nil }
        let averageWatts = dischargeWh * 3600 / seconds

        // fullEnergyWh 仅当容量与合理电压均真实可用；禁止默认 11.1V
        guard input.fullChargeCapacityMah > 0, input.voltageMV > 0 else { return nil }
        let voltageV = input.voltageMV / 1000
        // 合理性检查只用于拒绝坏数据，不夹成固定值
        guard (8.0...20.0).contains(voltageV), (1000...30_000).contains(input.fullChargeCapacityMah) else { return nil }
        let fullEnergyWh = Double(input.fullChargeCapacityMah) / 1000 * voltageV
        guard fullEnergyWh > 10 else { return nil }

        let rate = averageWatts * 100 / fullEnergyWh
        // 异常直接拒绝（不是夹到“合理区间”）
        guard rate > 0, rate < 100 else { return nil }

        // 当前电压瞬时值只能提供中等置信度（≤0.66）
        let confidence = min(0.66, 0.33 + 0.33 * coverage)
        return EstimationResult(
            confidence: confidence,
            basis: .batteryPower,
            valueHours: 0,
            ratePercentPerHour: rate,
            evidenceDuration: seconds,
            coverage: coverage
        )
    }

    /// IOPowerSources 的系统剩余时间：独立证据，永不与 App 证据静默混算。
    static func systemReportedEstimate(_ input: Inputs) -> EstimationResult? {
        guard input.externalConnected == false,
              input.systemReportedMinutes > 0
        else { return nil }
        return EstimationResult(
            confidence: 0.3,
            basis: .systemReported,
            valueHours: Double(input.systemReportedMinutes) / 60,
            ratePercentPerHour: input.systemReportedMinutes > 0
                ? input.currentLevel / (Double(input.systemReportedMinutes) / 60)
                : 0,
            evidenceDuration: 0,
            coverage: 0,
            failureReason: nil
        )
    }

    // MARK: - 充电时间

    /// 充电剩余时间估算。返回 nil = 数据不足 / 暂停 / 满电保持 / 无正增长。
    static func chargeEstimate(_ input: Inputs) -> EstimationResult? {
        guard input.externalConnected == true, input.isCharging else { return nil }
        guard input.currentLevel < 100 else { return nil }

        let windowStart = input.now.addingTimeInterval(-30 * 60)
        let points = input.snapshots
            .filter { $0.timestamp >= windowStart && $0.timestamp <= input.now }
            .filter { $0.isCharging && $0.externalConnected == true }
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.level) }
        guard points.count >= 2,
              let span = interval(points.first!.0, points.last!.0),
              span >= 5 * 60
        else { return nil }

        let gain = points.last!.1 - points.first!.1
        guard gain >= 1 else { return nil }

        // 充电是上升序列：direction -1 把成对斜率翻成正的充电速率
        let slopes = pairwiseSlopes(points: points, minimumPairInterval: 5 * 60, direction: -1)
        guard let median = median(of: slopes), median > 0 else { return nil }
        // 异常速率直接拒绝，不做区间夹值
        guard median <= 80 else { return nil }

        let coverage = coveredFraction(points: points, span: span)
        var confidence = clamp01(min(span / (30 * 60), gain / 5, max(coverage, 0.5))) * 0.9
        // 80% 以上涓流/优化充电阶段降低置信度
        if input.currentLevel > 80 { confidence *= 0.6 }

        return gated(EstimationResult(
            confidence: clamp01(confidence),
            basis: .historicalSlope,
            valueHours: (100 - input.currentLevel) / median,
            ratePercentPerHour: median,
            evidenceDuration: span,
            coverage: coverage,
            failureReason: input.currentLevel > 80 ? "涓流/优化充电阶段" : nil
        ))
    }

    // MARK: - 纯函数工具

    /// Theil–Sen 成对斜率的分布摘要（%/h）。仅统计间隔 ≥ minimumPairInterval 的点对。
    /// direction=1 用于下降序列（放电速率），-1 用于上升序列（充电速率）。
    static func pairwiseSlopes(
        points: [(Date, Double)],
        minimumPairInterval: TimeInterval,
        direction: Double = 1
    ) -> [Double] {
        var slopes: [Double] = []
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                guard let dt = interval(points[i].0, points[j].0), dt >= minimumPairInterval else { continue }
                slopes.append(direction * (points[i].1 - points[j].1) / (dt / 3600))
            }
        }
        return slopes
    }

    /// 中位数；空集返回 nil
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// 点序列的时间覆盖：并集([t, t+65s)) / 总跨度。量化电量点之间的常规采样间隔
    /// 计入覆盖，长缺口如实拉低。
    static func coveredFraction(points: [(Date, Double)], span: TimeInterval) -> Double {
        guard span > 0, !points.isEmpty else { return 0 }
        let grain: TimeInterval = 65
        var intervals: [(Double, Double)] = points.map {
            ($0.0.timeIntervalSince1970, $0.0.timeIntervalSince1970 + grain)
        }
        intervals.sort { $0.0 < $1.0 }
        var unioned: [Double] = []
        var currentStart = intervals[0].0
        var currentEnd = intervals[0].1
        for next in intervals.dropFirst() {
            if next.0 <= currentEnd {
                currentEnd = max(currentEnd, next.1)
            } else {
                unioned.append(currentEnd - currentStart)
                currentStart = next.0
                currentEnd = next.1
            }
        }
        unioned.append(currentEnd - currentStart)
        let covered = unioned.reduce(0, +)
        return clamp01(covered / span)
    }

    private static func interval(_ a: Date, _ b: Date) -> TimeInterval? {
        let dt = b.timeIntervalSince(a)
        return dt > 0 ? dt : nil
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
