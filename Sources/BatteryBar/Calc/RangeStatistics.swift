import Foundation

/// 功耗页范围统计的纯函数（无 SwiftUI 依赖，可独立反例测试）。
enum RangeStatistics {

    /// 所选范围的总覆盖率。冻结口径：
    /// - 分母是用户选择范围的墙钟时长（rangeStart→rangeEnd），
    ///   不是现存聚合点数量；
    /// - 完全缺失的分钟计为未覆盖；
    /// - 按 aggregateWindowStart 去重并限制到所选窗口；
    /// - 每分钟贡献 min(coverage,1)×60 秒，结果裁到 0...1。
    static func overallSystemCoverage(
        snapshots: [BatterySnapshot],
        rangeStart: Date,
        rangeEnd: Date
    ) -> Double {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        guard total > 0 else { return 0 }
        var seenWindows = Set<Date>()
        var coveredSeconds = 0.0
        for snap in snapshots {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= rangeStart, windowStart < rangeEnd,
                  !seenWindows.contains(windowStart)
            else { continue }
            seenWindows.insert(windowStart)
            coveredSeconds += min(1, max(0, snap.systemCoverage ?? 0)) * 60
        }
        return min(1, max(0, coveredSeconds / total))
    }

    /// 所选范围内的可信能耗合计：仅累加覆盖达标（≥0.8）的 systemEnergyWh，
    /// 按 aggregateWindowStart 去重并限制到所选窗口。
    static func trustedSystemEnergyWh(
        snapshots: [BatterySnapshot],
        rangeStart: Date,
        rangeEnd: Date,
        coverageThreshold: Double = 0.8
    ) -> Double {
        var seenWindows = Set<Date>()
        var energyWh = 0.0
        for snap in snapshots {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= rangeStart, windowStart < rangeEnd,
                  !seenWindows.contains(windowStart)
            else { continue }
            seenWindows.insert(windowStart)
            if let coverage = snap.systemCoverage, coverage >= coverageThreshold,
               let wh = snap.systemEnergyWh, wh.isFinite, wh >= 0 {
                energyWh += wh
            }
        }
        return energyWh
    }
}
