import Foundation

/// 检测充放电循环并记录
///
/// 一个 cycle = 一次完整的"放电阶段"（从拔电开始到插电结束）。
/// - 充电 → 放电：cycle 开始（记录 startLevel、startDate）
/// - 放电 → 充电：cycle 结束（duration > 300s 才保存）
///
/// 时钟与落盘通过 init 注入：生产环境用 Date() 与 DataStore，
/// 单元测试用可控时钟与 stub 收集器，避免真实等待 5 分钟。
final class CycleTracker {
    private var onSave: (ChargeCycle) -> Void
    private var now: () -> Date

    private var wasCharging: Bool?
    private var cycleStartLevel: Double = 0
    private var cycleStartDate: Date = Date()
    private var cycleWattageSamples: [Double] = []
    private var accumulatedDischarge: Double = 0
    // 上一个 tick 的电量：放电量按相邻 tick 电量差累加。
    // 旧实现每 tick 累加「起始电量 - 当前电量」，同一差值被重复累加，
    // 长循环的 totalEnergy 会随时长线性虚增（CycleTab 显示为「放电 X%」）。
    private var lastSeenLevel: Double?

    init(
        now: @escaping () -> Date = { Date() },
        onSave: @escaping (ChargeCycle) -> Void = { DataStore.shared.saveCycle($0) }
    ) {
        self.now = now
        self.onSave = onSave
    }

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
                cycleStartDate = now()
                lastSeenLevel = level
            }
            return
        }

        // 充电 → 放电：新循环开始（放电阶段）
        if prev && !isCharging {
            cycleStartLevel = level
            cycleStartDate = now()
            cycleWattageSamples = []
            accumulatedDischarge = 0
            lastSeenLevel = level
        }

        // 放电 → 充电：循环结束
        if !prev && isCharging {
            endCycle(endLevel: level)
        }

        // 累加放电量（相邻 tick 正向差值，忽略电量读数回跳）
        if !isCharging {
            if let last = lastSeenLevel {
                accumulatedDischarge += max(0, last - level)
            }
            lastSeenLevel = level
        }
    }

    private func endCycle(endLevel: Double) {
        let duration = now().timeIntervalSince(cycleStartDate)
        // 过滤无效循环：时长不足 5 分钟，或电量下降不足 1%
        //（满电时拔电又迅速插电会产生 100%→100% 的脏数据）
        guard duration > 300, (cycleStartLevel - endLevel) >= 1 else { return }

        let avgWatt = cycleWattageSamples.isEmpty ? 0 : cycleWattageSamples.reduce(0, +) / Double(cycleWattageSamples.count)

        let cycle = ChargeCycle(
            startDate: cycleStartDate,
            endDate: now(),
            startLevel: cycleStartLevel,
            endLevel: endLevel,
            totalEnergy: accumulatedDischarge,
            averageWattage: avgWatt
        )
        onSave(cycle)
    }
}
