import Foundation

/// 检测离电使用时段并记录
///
/// 一个 record = 一次完整的"离电使用时段"（从拔电开始到插电结束）。
/// 状态机只认**插拔状态**（externalConnected）：
/// - 接电 → 离电：record 开始（记录 startLevel、startDate）
/// - 离电 → 接电：record 结束（duration > 300s 才保存）
///
/// ⚠️ 不得用 isCharging 判断是否接电：满电保持、优化充电暂停、80% 上限
/// 都是接电未充电状态，按充电状态分段会把整段接电时间误记为"离电使用"。
///
/// 时钟与落盘通过 init 注入：生产环境用 Date() 与 DataStore，
/// 单元测试用可控时钟与 stub 收集器。
final class CycleTracker {
    private var onSave: (ChargeCycle) -> Void
    private var now: () -> Date

    private var wasPluggedIn: Bool?
    private var cycleStartLevel: Double = 0
    private var cycleStartDate: Date = Date()
    private var batteryPowerSamples: [Double] = []
    private var accumulatedDischarge: Double = 0
    // 上一个 tick 的电量：放电量按相邻 tick 电量差累加，
    // 避免同一差值被重复累加导致 totalEnergy 虚增。
    private var lastSeenLevel: Double?

    init(
        now: @escaping () -> Date = { Date() },
        onSave: @escaping (ChargeCycle) -> Void = { DataStore.shared.saveCycle($0) }
    ) {
        self.now = now
        self.onSave = onSave
    }

    /// - Parameters:
    ///   - isPluggedIn: 是否接外接电源（externalConnected），不是 isCharging
    ///   - level: 当前电量百分比
    ///   - batteryPower: 电池包充入/放出功率绝对值（瓦特）
    func update(isPluggedIn: Bool, level: Double, batteryPower: Double) {
        defer { wasPluggedIn = isPluggedIn }

        guard let prev = wasPluggedIn else {
            // 首次初始化：若启动时已离电，把当前状态作为 record 起点
            if !isPluggedIn {
                cycleStartLevel = level
                cycleStartDate = now()
                lastSeenLevel = level
            }
            return
        }

        // 接电 → 离电：新 record 开始
        if prev && !isPluggedIn {
            cycleStartLevel = level
            cycleStartDate = now()
            batteryPowerSamples = []
            accumulatedDischarge = 0
            lastSeenLevel = level
        }

        // 离电 → 接电：record 结束
        if !prev && isPluggedIn {
            endCycle(endLevel: level)
        }

        if !isPluggedIn {
            batteryPowerSamples.append(batteryPower)
            // 累加放电量（相邻 tick 正向差值，忽略电量读数回跳）
            if let last = lastSeenLevel {
                accumulatedDischarge += max(0, last - level)
            }
            lastSeenLevel = level
        }
    }

    private func endCycle(endLevel: Double) {
        let duration = now().timeIntervalSince(cycleStartDate)
        // 过滤无效记录：时长不足 5 分钟，或电量下降不足 1%
        guard duration > 300, (cycleStartLevel - endLevel) >= 1 else { return }

        let avgWatt = batteryPowerSamples.isEmpty ? 0 : batteryPowerSamples.reduce(0, +) / Double(batteryPowerSamples.count)

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
