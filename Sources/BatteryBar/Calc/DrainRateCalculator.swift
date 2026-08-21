import Foundation
import IOKit

/// 放电/充电速率计算器（纯函数集合）
///
/// 抽取自 UsageTab 和 PopoverView 的重复实现，统一算法确保 Popover 与主窗口显示一致。
/// 由 PowerSampler 定期调用并缓存结果，避免 View body 每 tick 全量扫描 DataStore。
/// 快照数组与时间通过参数注入（now 默认 Date()），不直接依赖 DataStore / 系统时钟，
/// 单元测试可用构造的快照序列与固定时间验证算法。
enum DrainRateCalculator {

    /// 放电速率（每小时耗电百分比），结合历史数据 + 当前功率 + 机型基准，做平滑处理。
    /// - Parameters:
    ///   - level: 当前电量
    ///   - isCharging: 当前是否充电
    ///   - wattage: 当前功率
    ///   - voltage: 当前电压（mV）
    ///   - maxCapacity: 电池最大容量（mAh 或 IORegistry 单位）
    ///   - healthPercent: 电池健康度（0-100）
    ///   - dischargeStart: 当前离电周期开始时间（用于判断拔电初期）
    ///   - snapshots: 近期快照（建议传最近 1440 条，即 24h）
    ///   - now: 当前时间（测试注入用）
    static func drainRate(
        level: Double,
        isCharging: Bool,
        wattage: Double,
        voltage: Double,
        maxCapacity: Int,
        healthPercent: Double,
        dischargeStart: Date?,
        snapshots: [BatterySnapshot],
        now: Date = Date()
    ) -> Double {
        // 判断是否在拔电初期（前2分钟功率不稳定）
        let isInitialPhase: Bool
        if let start = dischargeStart {
            isInitialPhase = now.timeIntervalSince(start) < 120
        } else {
            isInitialPhase = false
        }

        // === 1. 历史放电段速率（滑动窗口中位数平滑）===
        let segments = chargeSegments(from: snapshots)
        var historyRate: Double = 0
        if let lastSegment = segments.last {
            let segmentSnaps = snapshots.filter {
                $0.timestamp >= lastSegment.start && $0.timestamp <= lastSegment.end && !$0.isCharging
            }.sorted { $0.timestamp < $1.timestamp }

            if segmentSnaps.count >= 2 {
                var windowRates: [Double] = []
                let windowSize = min(5, max(2, segmentSnaps.count - 1))
                for i in 0..<(segmentSnaps.count - windowSize) {
                    let start = segmentSnaps[i]
                    let end = segmentSnaps[i + windowSize]
                    let hours = end.timestamp.timeIntervalSince(start.timestamp) / 3600
                    if hours > 0 {
                        let r = abs(start.level - end.level) / hours
                        if r > 0 { windowRates.append(r) }
                    }
                }
                if windowRates.isEmpty, segmentSnaps.count >= 2 {
                    let hours = segmentSnaps.last!.timestamp.timeIntervalSince(segmentSnaps.first!.timestamp) / 3600
                    if hours > 0 {
                        let r = abs(segmentSnaps.first!.level - segmentSnaps.last!.level) / hours
                        if r > 0 { historyRate = r }
                    }
                } else if !windowRates.isEmpty {
                    windowRates.sort()
                    historyRate = windowRates[windowRates.count / 2]
                }
            }
        }

        // === 2. 当前功率估算速率 ===
        var powerRate: Double = 0
        let smoothWattage = smoothedWattage(snapshots: snapshots, seconds: 300, now: now, fallback: wattage)
        if smoothWattage > 0.1, maxCapacity > 0 {
            // 限制异常功率：超过 30W 视为异常
            let cappedWattage = min(smoothWattage, 30)
            let v = voltage > 0 ? voltage / 1000.0 : 11.1
            let batteryEnergyWh = Double(maxCapacity) * v / 1000.0
            if batteryEnergyWh > 0 {
                powerRate = cappedWattage * 100 / batteryEnergyWh
            }
        }

        // === 拔电初期：优先历史数据，无历史用机型基准预估 ===
        if isInitialPhase {
            if historyRate > 0 { return historyRate }
            return machineBaselineDrainRate(healthPercent: healthPercent, maxCapacity: maxCapacity, voltage: voltage)
        }

        // === 正常阶段：融合历史权重 0.6 + 当前功率权重 0.4 ===
        if historyRate > 0 && powerRate > 0 {
            return historyRate * 0.6 + powerRate * 0.4
        } else if historyRate > 0 {
            return historyRate
        } else if powerRate > 0 {
            return powerRate
        }
        return machineBaselineDrainRate(healthPercent: healthPercent, maxCapacity: maxCapacity, voltage: voltage)
    }

    /// 充电速率（每小时充电百分比）
    /// 取最近 30 分钟内的充电快照，要求足够的时间跨度与电量变化，
    /// 避免短窗口 + 小变化导致的剧烈跳变（如 7h → 15h）。
    static func chargeRate(snapshots: [BatterySnapshot], now: Date = Date()) -> Double {
        let cutoff = now.addingTimeInterval(-1800)
        let recent = snapshots.filter { $0.isCharging && $0.timestamp >= cutoff }
        guard recent.count >= 3 else { return 0 }
        let sorted = recent.sorted { $0.timestamp < $1.timestamp }
        let hours = sorted.last!.timestamp.timeIntervalSince(sorted.first!.timestamp) / 3600
        let delta = abs(sorted.last!.level - sorted.first!.level)
        // 跨度不足 4 分钟或变化不足 1%：样本噪声太大，不给出速率
        guard hours >= 4.0 / 60, delta >= 1 else { return 0 }
        let rate = delta / hours
        // 合理区间限制：3-80%/h（超过 80%/h 必是异常采样）
        return min(max(rate, 3), 80)
    }

    /// 机型基准放电速率（%/h）。
    ///
    /// 优先用实测电池能量（满充容量 × 电压）+ 机型典型整机功耗估算：
    ///   rate = 典型功耗(W) × 100 / 电池能量(Wh)
    /// 满充容量本身已反映健康度衰减，此路径不再叠加健康度因子。
    ///
    /// 注意不能按 hw.model 里的 "m1"/"m2" 子串判断芯片代次：
    /// Apple Silicon 的 hw.model 是 "Mac14,2" 这类平台键，或过渡期的
    /// "MacBookAir10,1"（同样不含 "m1" 子串），按子串分类永远匹配不到。
    static func machineBaselineDrainRate(
        healthPercent: Double,
        maxCapacity: Int,
        voltage: Double,
        model: String = readMachineModel()
    ) -> Double {
        let m = model.lowercased()
        let watts = typicalSystemWatts(model: m)
        let v = voltage > 0 ? voltage / 1000.0 : 11.1
        let energyWh = Double(maxCapacity) * v / 1000.0
        if maxCapacity > 0, energyWh > 0 {
            return watts * 100 / energyWh
        }
        // 容量未知：退回固定速率表，健康度低 = 同样功耗下百分比掉得更快
        let healthFactor = healthPercent > 0 ? 100.0 / max(50, healthPercent) : 1.0
        return fallbackRate(model: m) * healthFactor
    }

    /// 机型典型中等负载整机功耗（W）
    private static func typicalSystemWatts(model: String) -> Double {
        if model.contains("macbookair") { return 6.0 }
        if model.contains("macbookpro") { return 9.0 }
        if model.contains("macbook") { return 8.0 }
        return 8.0
    }

    /// 容量未知时的兜底速率（%/h，Intel 时代经验值）
    private static func fallbackRate(model: String) -> Double {
        if model.contains("macbookpro") { return 13.0 }
        if model.contains("macbookair") { return 12.0 }
        if model.contains("macbook") { return 12.0 }
        return 10.0
    }

    /// 最近 N 秒内的功率滑动平均（去掉极值），用于平滑瞬时波动。
    /// 只使用离电快照，避免充电时的高功率拉高平均值。
    private static func smoothedWattage(snapshots: [BatterySnapshot], seconds: TimeInterval, now: Date, fallback: Double) -> Double {
        let cutoff = now.addingTimeInterval(-seconds)
        let recent = snapshots.filter { $0.timestamp >= cutoff && !$0.isCharging }
        let watts = recent.map { abs($0.wattage) }.filter { $0 > 0.1 }
        guard !watts.isEmpty else { return fallback }
        let sorted = watts.sorted()
        let trim = max(1, sorted.count / 10)
        let trimmed = Array(sorted.dropFirst(trim).dropLast(trim))
        return trimmed.isEmpty ? sorted[sorted.count / 2] : trimmed.reduce(0, +) / Double(trimmed.count)
    }

    private static func chargeSegments(from snapshots: [BatterySnapshot]) -> [(start: Date, end: Date)] {
        var segments: [(start: Date, end: Date)] = []
        var currentStart: Date?
        var wasCharging: Bool?
        for snap in snapshots {
            if let prev = wasCharging {
                if prev && !snap.isCharging {
                    currentStart = snap.timestamp
                } else if !prev && snap.isCharging {
                    if let start = currentStart {
                        segments.append((start: start, end: snap.timestamp))
                    }
                    currentStart = nil
                }
            } else if !snap.isCharging {
                currentStart = snap.timestamp
            }
            wasCharging = snap.isCharging
        }
        if let start = currentStart, let last = snapshots.last {
            segments.append((start: start, end: last.timestamp))
        }
        return segments
    }

    /// 读取 sysctl hw.model（如 "MacBookAir10,1" 或 Apple Silicon 的 "Mac14,2"）
    private static func readMachineModel() -> String {
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                return String(cString: buffer)
            }
        }
        return ""
    }
}
