import Foundation

/// 检测充放电循环并记录
///
/// 一个 cycle = 一次完整的"放电阶段"（从拔电开始到插电结束）。
/// - 充电 → 放电：cycle 开始（记录 startLevel、startDate）
/// - 放电 → 充电：cycle 结束（duration > 300s 才保存）
final class CycleTracker: @unchecked Sendable {
    private var wasCharging: Bool?
    private var cycleStartLevel: Double = 0
    private var cycleStartDate: Date = Date()
    private var cycleWattageSamples: [Double] = []
    private var accumulatedDischarge: Double = 0

    func update(isCharging: Bool, level: Double, wattage: Double) {
        defer { wasCharging = isCharging }

        // 在每次 update 时记录 wattage（仅放电期间），供 averageWattage 计算
        if !isCharging {
            cycleWattageSamples.append(wattage)
        }

        guard let prev = wasCharging else {
            // 首次初始化：若启动时在放电，把当前状态作为 cycle 起点
            if !isCharging {
                cycleStartLevel = level
                cycleStartDate = Date()
            }
            return
        }

        // 充电 → 放电：新循环开始（放电阶段）
        if prev && !isCharging {
            cycleStartLevel = level
            cycleStartDate = Date()
            cycleWattageSamples = []
            accumulatedDischarge = 0
        }

        // 放电 → 充电：循环结束
        if !prev && isCharging {
            endCycle(endLevel: level)
        }

        // 累加放电量（仅放电期间，cycleStartLevel - level 为正数）
        if !isCharging {
            accumulatedDischarge += max(0, cycleStartLevel - level)
        }
    }

    private func endCycle(endLevel: Double) {
        let duration = Date().timeIntervalSince(cycleStartDate)
        guard duration > 300 else { return }

        let avgWatt = cycleWattageSamples.isEmpty ? 0 : cycleWattageSamples.reduce(0, +) / Double(cycleWattageSamples.count)

        let cycle = ChargeCycle(
            startDate: cycleStartDate,
            endDate: Date(),
            startLevel: cycleStartLevel,
            endLevel: endLevel,
            totalEnergy: accumulatedDischarge,
            averageWattage: avgWatt
        )
        DataStore.shared.saveCycle(cycle)
    }
}
