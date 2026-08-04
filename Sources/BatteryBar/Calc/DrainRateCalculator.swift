import Foundation
import IOKit

/// 放电/充电速率计算器（共享单例）
///
/// 抽取自 UsageTab 和 PopoverView 的重复实现，统一算法确保 Popover 与主窗口显示一致。
/// 由 PowerSampler 定期调用并缓存结果，避免 View body 每 tick 全量扫描 DataStore。
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
    static func drainRate(
        level: Double,
        isCharging: Bool,
        wattage: Double,
        voltage: Double,
        maxCapacity: Int,
        healthPercent: Double,
        dischargeStart: Date?
    ) -> Double {
        // 判断是否在拔电初期（前2分钟功率不稳定）
        let isInitialPhase: Bool
        if let start = dischargeStart {
            isInitialPhase = Date().timeIntervalSince(start) < 120
        } else {
            isInitialPhase = false
        }

        let snaps = DataStore.shared.recentSnapshots(1440)

        // === 1. 历史放电段速率（滑动窗口中位数平滑）===
        let segments = chargeSegments(from: snaps)
        var historyRate: Double = 0
        if let lastSegment = segments.last {
            let segmentSnaps = snaps.filter {
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
        let smoothWattage = smoothedWattage(seconds: 300, fallback: wattage)
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
            return machineBaselineDrainRate(healthPercent: healthPercent)
        }

        // === 正常阶段：融合历史权重 0.6 + 当前功率权重 0.4 ===
        if historyRate > 0 && powerRate > 0 {
            return historyRate * 0.6 + powerRate * 0.4
        } else if historyRate > 0 {
            return historyRate
        } else if powerRate > 0 {
            return powerRate
        }
        return machineBaselineDrainRate(healthPercent: healthPercent)
    }

    /// 充电速率（每小时充电百分比）
    /// 取最近 30 分钟内的充电快照，要求足够的时间跨度与电量变化，
    /// 避免短窗口 + 小变化导致的剧烈跳变（如 7h → 15h）。
    static func chargeRate() -> Double {
        let cutoff = Date().addingTimeInterval(-1800)
        let recent = DataStore.shared.recentSnapshots(60)
            .filter { $0.isCharging && $0.timestamp >= cutoff }
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

    /// 机型基准放电速率（%/h），根据机型和电池健康度调整。
    /// 通过 sysctl hw.model 检测机型，避免硬编码仅适配 MacBook Air M1。
    static func machineBaselineDrainRate(healthPercent: Double) -> Double {
        let baseline = machineBaselineRate()
        // 健康度低 = 实际容量小于设计容量 = 同样功耗下百分比掉得更快
        let healthFactor = healthPercent > 0 ? 100.0 / max(50, healthPercent) : 1.0
        return baseline * healthFactor
    }

    /// 最近 N 秒内的功率滑动平均（去掉极值），用于平滑瞬时波动。
    /// 只使用离电快照，避免充电时的高功率拉高平均值。
    private static func smoothedWattage(seconds: TimeInterval, fallback: Double) -> Double {
        let cutoff = Date().addingTimeInterval(-seconds)
        let recent = DataStore.shared.recentSnapshots(Int(seconds / 60) + 2)
            .filter { $0.timestamp >= cutoff && !$0.isCharging }
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

    /// 通过 sysctl hw.model 读取机型标识，返回对应基准放电速率（%/h）。
    /// 覆盖 MacBook Air/Pro、MacBook 等；未知机型兜底 10%/h。
    private static func machineBaselineRate() -> Double {
        let model = readMachineModel().lowercased()

        // MacBook Pro 功耗更高（高性能芯片 + ProMotion 屏幕）
        if model.contains("macbookpro") {
            if model.contains("m1") || model.contains("m2") { return 13.0 }
            if model.contains("m3") || model.contains("m4") { return 12.5 }
            return 15.0  // Intel MacBook Pro
        }
        // MacBook Air（能效优先）
        if model.contains("macbookair") {
            if model.contains("m1") { return 10.0 }
            if model.contains("m2") || model.contains("m3") || model.contains("m4") { return 9.0 }
            return 12.0  // Intel MacBook Air
        }
        // 旧款 MacBook
        if model.contains("macbook") { return 12.0 }
        // Mac mini / iMac / Mac Studio（接电源使用，无电池，不会走到这里）
        return 10.0
    }

    /// 读取 sysctl hw.model（如 "MacBookAir10,1"）
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
