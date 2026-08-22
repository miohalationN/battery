import Foundation

/// 概览页时段分析模型：当前离电时段 / 当前接电时段 / 上次充电摘要。
///
/// 分段只认 `externalConnected`（插拔状态）；`externalConnected` 未知的旧点
/// 不参与任何时段——满电保持、优化充电暂停、80% 上限都是接电未充电，
/// 按 isCharging 分段会把整段接电时间误判为离电使用。
/// 由快照通知与时段切换触发重算（UsageTab.reloadSession），
/// View body 只消费结果，不做扫描与统计。
@MainActor
@Observable
final class UsageSessionModel {
    enum SessionKind: Equatable {
        case currentDischarge
        case currentCharge
        case lastCharge
    }

    struct Point: Equatable {
        let relMin: Double
        let level: Double
        let time: Date

        init(relMin: Double, level: Double, time: Date) {
            self.relMin = relMin
            self.level = level
            self.time = time
        }
    }

    struct Summary: Equatable {
        var startLevel: Double = 0
        var endLevel: Double = 0
        var deltaPercent: Double = 0
        var avgBatteryWatts: Double = 0
        var durationMin: Double = 0

        init(startLevel: Double = 0, endLevel: Double = 0, deltaPercent: Double = 0, avgBatteryWatts: Double = 0, durationMin: Double = 0) {
            self.startLevel = startLevel
            self.endLevel = endLevel
            self.deltaPercent = deltaPercent
            self.avgBatteryWatts = avgBatteryWatts
            self.durationMin = durationMin
        }
    }

    private(set) var isCharging = false
    private(set) var points: [Point] = []
    private(set) var summary = Summary()

    var cardTitle: String {
        switch kind {
        case .currentDischarge: return "本次离电使用"
        case .currentCharge: return "本次充电"
        case .lastCharge: return "上次充电摘要"
        }
    }

    var emptyTitle: String {
        kind == .lastCharge ? "暂无有效充电记录" : "正在建立电量曲线"
    }

    private(set) var kind: SessionKind = .currentDischarge

    /// 曲线点数上限：超出时按均匀步长抽稀并保留末点，防止长时段渲染退化
    private static let maxPoints = 480

    init() {}

    func reload(snapshots: [BatterySnapshot], kind: SessionKind) {
        self.kind = kind
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        switch kind {
        case .currentDischarge:
            buildSession(from: sorted, wantExternal: false, title: "本次离电使用")
        case .currentCharge:
            buildSession(from: sorted, wantExternal: true, title: "本次充电")
        case .lastCharge:
            buildLastCharge(from: sorted)
        }
    }

    // MARK: - 当前时段（按 externalConnected 切换点分段）

    /// 最后一次切到目标电源状态的点；找不到时回退到第一个同状态点。
    /// 只在 externalConnected 已知的快照中寻找。
    static func sessionStart(in sorted: [BatterySnapshot], pluggedIn target: Bool) -> Date? {
        let known = sorted.filter { $0.externalConnected != nil }
        var prev: Bool?
        var start: Date?
        for snap in known {
            let state = snap.externalConnected == true
            if let p = prev, p != state, state == target {
                start = snap.timestamp
            }
            prev = state
        }
        if start == nil {
            start = known.first(where: { ($0.externalConnected == true) == target })?.timestamp
        }
        return start
    }

    private func buildSession(from sorted: [BatterySnapshot], wantExternal plugged: Bool, title: String) {
        isCharging = plugged ? true : false
        guard let start = Self.sessionStart(in: sorted, pluggedIn: plugged) else {
            points = []
            summary = Summary()
            return
        }
        // 时段内只取电源状态已知的同侧点，未知来源的旧点不画进曲线
        let sessionSnaps = sorted.filter {
            $0.timestamp >= start && $0.externalConnected != nil && ($0.externalConnected == true) == plugged
        }
        guard !sessionSnaps.isEmpty else {
            points = []
            summary = Summary()
            return
        }
        let filtered = Self.changedLevelPoints(sessionSnaps)
        points = Self.downsample(filtered).map { snap in
            Point(relMin: snap.timestamp.timeIntervalSince(start) / 60, level: snap.level, time: snap.timestamp)
        }
        summary = Self.makeSummary(sessionSnaps: sessionSnaps, start: start, charging: plugged)
    }

    /// 上次充电摘要：最近一个接电时段。必须有正电量变化（≥1%）且时长 ≥5 分钟，
    /// 否则保持空态——禁止展示"100%→100%、已充入 0% 却有平均功率"的假摘要。
    private func buildLastCharge(from sorted: [BatterySnapshot]) {
        isCharging = true
        guard let start = Self.sessionStart(in: sorted, pluggedIn: true) else {
            points = []
            summary = Summary()
            return
        }
        let sessionSnaps = sorted.filter {
            $0.timestamp >= start && $0.externalConnected != nil && $0.externalConnected == true
        }
        guard let first = sessionSnaps.first, let last = sessionSnaps.last,
              last.level - first.level >= 1,
              last.timestamp.timeIntervalSince(first.timestamp) >= 300
        else {
            points = []
            summary = Summary()
            return
        }
        let filtered = Self.changedLevelPoints(sessionSnaps)
        points = Self.downsample(filtered).map { snap in
            Point(relMin: snap.timestamp.timeIntervalSince(first.timestamp) / 60, level: snap.level, time: snap.timestamp)
        }
        summary = Self.makeSummary(sessionSnaps: sessionSnaps, start: first.timestamp, charging: true)
    }

    // MARK: - 纯函数工具

    /// 只保留电量有变化的点（首点与其后每个新电量值）；末点始终保留
    static func changedLevelPoints(_ snaps: [BatterySnapshot]) -> [BatterySnapshot] {
        var filtered: [BatterySnapshot] = []
        var lastLevel: Double?
        for snap in snaps {
            if lastLevel == nil || snap.level != lastLevel {
                filtered.append(snap)
                lastLevel = snap.level
            }
        }
        if let last = snaps.last, filtered.last?.id != last.id {
            filtered.append(last)
        }
        return filtered
    }

    /// 曲线点数上限：超出时按均匀步长抽稀并保留末点
    static func downsample(_ snaps: [BatterySnapshot]) -> [BatterySnapshot] {
        guard snaps.count > maxPoints else { return snaps }
        let step = Double(snaps.count) / Double(maxPoints)
        var result: [BatterySnapshot] = []
        var cursor = 0.0
        while Int(cursor) < snaps.count - 1 {
            result.append(snaps[Int(cursor)])
            cursor += step
        }
        if let last = snaps.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }

    /// 时段摘要。平均电池功率：充电时段只取 isCharging 的样本（优化充电暂停的
    /// ≈0W 不稀释"平均功率"）；离电时段取 >0 的放出功率。
    static func makeSummary(sessionSnaps: [BatterySnapshot], start: Date, charging: Bool) -> Summary {
        guard let first = sessionSnaps.first, let last = sessionSnaps.last else { return Summary() }
        let delta = charging ? last.level - first.level : first.level - last.level
        let watts = sessionSnaps
            .filter { charging ? $0.isCharging : true }
            .map(\.batteryPower)
            .filter { $0 > 0 }
        let avg = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)
        return Summary(
            startLevel: first.level,
            endLevel: last.level,
            deltaPercent: delta,
            avgBatteryWatts: avg,
            durationMin: last.timestamp.timeIntervalSince(start) / 60
        )
    }
}
