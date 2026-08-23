import Foundation

/// 离电记录（一次离电使用时段）的展示与趋势分析。
///
/// 注意：这里的「记录」是本 app 自己检测的离电使用时段，不是 Apple 的电池循环次数
/// （CycleCount，来自 IORegistry，在概览页健康指标中展示）。
///
/// 直接比较每段 duration 不公平：100%→10% 与 50%→30% 的时长不可比。
/// 趋势比较只用归一化指标：
/// - percentPerHour：每小时耗电百分比（越小越省电）
/// - fullChargeHours：折算满电续航小时 = 时长 ÷ 下降幅度 × 100（越大续航越好）
/// 只有电量下降 ≥ minDropPercent 且持续 ≥ minDurationSeconds 的记录参与归一化，
/// 样本不足时调用方必须明确显示「数据不足」，不得制造假趋势。
enum OffPowerRecordAnalyzer {
    struct NormalizedRecord: Equatable {
        let cycle: ChargeCycle
        /// 每小时耗电百分比
        let percentPerHour: Double
        /// 折算满电续航（小时）
        let fullChargeHours: Double

        static func == (lhs: NormalizedRecord, rhs: NormalizedRecord) -> Bool {
            lhs.cycle.id == rhs.cycle.id
                && lhs.percentPerHour == rhs.percentPerHour
                && lhs.fullChargeHours == rhs.fullChargeHours
        }
    }

    /// 展示用记录：过滤旧版本误存的充电段与电量下降不足 1% 的脏数据。
    static func displayableRecords(from cycles: [ChargeCycle]) -> [ChargeCycle] {
        cycles
            .filter { $0.duration >= 300 && $0.startLevel - $0.endLevel >= 1 }
            .sorted { $0.startDate < $1.startDate }
    }

    /// 参与趋势比较的归一化记录。门槛默认：下降 ≥5%、时长 ≥15 分钟。
    static func normalizedRecords(
        from cycles: [ChargeCycle],
        minDropPercent: Double = 5,
        minDurationSeconds: TimeInterval = 900
    ) -> [NormalizedRecord] {
        displayableRecords(from: cycles).compactMap { cycle in
            let drop = cycle.startLevel - cycle.endLevel
            guard drop >= minDropPercent, cycle.duration >= minDurationSeconds, cycle.duration > 0 else { return nil }
            let percentPerHour = drop / (cycle.duration / 3600)
            guard percentPerHour > 0 else { return nil }
            return NormalizedRecord(
                cycle: cycle,
                percentPerHour: percentPerHour,
                fullChargeHours: 100 / percentPerHour
            )
        }
    }

    /// 归一化指标的平均值（无有效记录时返回 nil）
    static func averageFullChargeHours(of records: [NormalizedRecord]) -> Double? {
        guard !records.isEmpty else { return nil }
        return records.map(\.fullChargeHours).reduce(0, +) / Double(records.count)
    }

    /// 长期记录图表按桶保留局部最小/最大续航，避免数年历史生成数千个 Chart marks。
    /// 汇总平均值仍由完整 records 计算，降采样只影响绘制。
    static func chartRecords(_ records: [NormalizedRecord], maxPoints: Int = 240) -> [NormalizedRecord] {
        guard maxPoints > 0 else { return [] }
        guard records.count > maxPoints else { return records }
        if maxPoints == 1 { return records.first.map { [$0] } ?? [] }
        let sorted = records.sorted { $0.cycle.startDate < $1.cycle.startDate }
        if maxPoints == 2 { return [sorted[0], sorted[sorted.count - 1]] }

        let interiorCount = sorted.count - 2
        let bucketCount = max(1, (maxPoints - 2) / 2)
        var indices = [0]
        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }
            let range = lower..<upper
            let minimum = range.min { sorted[$0].fullChargeHours < sorted[$1].fullChargeHours }
            let maximum = range.max { sorted[$0].fullChargeHours < sorted[$1].fullChargeHours }
            for index in [minimum, maximum].compactMap({ $0 }).sorted() where indices.last != index {
                indices.append(index)
            }
        }
        let last = sorted.count - 1
        if indices.last != last { indices.append(last) }
        return indices.map { sorted[$0] }
    }
}
