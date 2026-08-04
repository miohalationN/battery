import Foundation

/// JSON 文件持久化，替代 SwiftData
final class DataStore: @unchecked Sendable {
    static let shared = DataStore()

    private let baseDir: URL
    private let snapshotsFile: URL
    private let cyclesFile: URL
    private let configFile: URL
    private let usageStateFile: URL
    private let refreshIntervalFile: URL
    private let queue = DispatchQueue(label: "com.batterybar.store", qos: .utility)

    private var snapshots: [BatterySnapshot] = []
    private var cycles: [ChargeCycle] = []
    private var syncConfig: SyncConfig = .default
    private var usageState: UsageState = UsageState()
    private var storedRefreshInterval: Double = 1

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("BatteryBar", isDirectory: true)
        snapshotsFile = baseDir.appendingPathComponent("snapshots.json")
        cyclesFile = baseDir.appendingPathComponent("cycles.json")
        configFile = baseDir.appendingPathComponent("sync-config.json")
        usageStateFile = baseDir.appendingPathComponent("usage-state.json")
        refreshIntervalFile = baseDir.appendingPathComponent("refresh-interval.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        load()
        usageState = loadJSON(from: usageStateFile) ?? UsageState()
        if let data = try? Data(contentsOf: refreshIntervalFile),
           let v = try? JSONDecoder().decode(Double.self, from: data) {
            storedRefreshInterval = v
        }
    }

    func load() {
        queue.sync {
            snapshots = loadJSON(from: snapshotsFile) ?? []
            cycles = loadJSON(from: cyclesFile) ?? []
            syncConfig = loadJSON(from: configFile) ?? .default
        }
    }

    // MARK: - Snapshots

    func saveSnapshot(_ snap: BatterySnapshot) {
        queue.async { [self] in
            snapshots.append(snap)
            // 只保留最近 24h（1440 条）
            if snapshots.count > 2000 {
                snapshots = Array(snapshots.suffix(1440))
            }
            saveJSON(snapshots, to: snapshotsFile)
        }
    }

    /// 线程安全地读取全部快照（拷贝）
    func allSnapshots() -> [BatterySnapshot] {
        queue.sync { snapshots }
    }

    /// 线程安全地读取最近 count 条快照
    func recentSnapshots(_ count: Int) -> [BatterySnapshot] {
        queue.sync { Array(snapshots.suffix(count)) }
    }

    func dirtySnapshots() -> [BatterySnapshot] {
        queue.sync { snapshots.filter { $0.dirty } }
    }

    func markSnapshotsSynced(_ ids: Set<UUID>) {
        queue.async { [self] in
            for i in snapshots.indices where ids.contains(snapshots[i].id) {
                snapshots[i].dirty = false
            }
            saveJSON(snapshots, to: snapshotsFile)
        }
    }

    /// 合并远程快照：相同 UUID 时保留 timestamp 较新者（last-write-wins）
    func mergeSnapshots(_ remote: [BatterySnapshot]) {
        queue.async { [self] in
            var byID: [UUID: BatterySnapshot] = [:]
            // 本地先入表
            for snap in snapshots { byID[snap.id] = snap }
            // 远程覆盖：仅当 timestamp 更新时替换
            for snap in remote {
                if let existing = byID[snap.id] {
                    if snap.timestamp > existing.timestamp {
                        byID[snap.id] = snap
                    }
                } else {
                    byID[snap.id] = snap
                }
            }
            snapshots = byID.values.sorted { $0.timestamp < $1.timestamp }
            saveJSON(snapshots, to: snapshotsFile)
        }
    }

    // MARK: - Cycles

    func saveCycle(_ cycle: ChargeCycle) {
        queue.async { [self] in
            cycles.append(cycle)
            saveJSON(cycles, to: cyclesFile)
        }
    }

    /// 线程安全地读取全部循环记录（拷贝）
    func allCycles() -> [ChargeCycle] {
        queue.sync { cycles }
    }

    func dirtyCycles() -> [ChargeCycle] {
        queue.sync { cycles.filter { $0.dirty } }
    }

    func markCyclesSynced(_ ids: Set<UUID>) {
        queue.async { [self] in
            for i in cycles.indices where ids.contains(cycles[i].id) {
                cycles[i].dirty = false
            }
            saveJSON(cycles, to: cyclesFile)
        }
    }

    /// 合并远程循环：相同 UUID 时保留 startDate 较新者（last-write-wins）
    func mergeCycles(_ remote: [ChargeCycle]) {
        queue.async { [self] in
            var byID: [UUID: ChargeCycle] = [:]
            for c in cycles { byID[c.id] = c }
            for var c in remote {
                // 远程数据不应为 dirty，避免下载后被误认为待上传导致无限重传
                c.dirty = false
                if let existing = byID[c.id] {
                    if c.startDate > existing.startDate {
                        byID[c.id] = c
                    }
                } else {
                    byID[c.id] = c
                }
            }
            cycles = byID.values.sorted { $0.startDate < $1.startDate }
            saveJSON(cycles, to: cyclesFile)
        }
    }

    // MARK: - Config

    /// 线程安全地读取当前同步配置（拷贝）
    func currentConfig() -> SyncConfig {
        queue.sync { syncConfig }
    }

    /// 线程安全地更新同步配置并落盘
    func updateConfig(_ config: SyncConfig) {
        queue.async { [self] in
            syncConfig = config
            saveJSON(syncConfig, to: configFile)
        }
    }

    /// 只更新 lastSyncAt 字段，避免覆盖用户在同步期间修改的其他配置（TOCTOU）
    func updateLastSyncAt(_ date: Date) {
        queue.async { [self] in
            syncConfig.lastSyncAt = date
            saveJSON(syncConfig, to: configFile)
        }
    }

    func saveConfig() {
        queue.async { [self] in
            saveJSON(syncConfig, to: configFile)
        }
    }

    // MARK: - Usage State（时长持久化）

    /// 线程安全地读取使用时长状态
    func loadUsageState() -> UsageState {
        queue.sync { usageState }
    }

    /// 线程安全地保存使用时长状态
    func saveUsageState(_ state: UsageState) {
        queue.async { [self] in
            var s = state
            s.lastSavedAt = Date()
            usageState = s
            saveJSON(s, to: usageStateFile)
        }
    }

    // MARK: - JSON helpers

    private func loadJSON<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Refresh Interval（UI 刷新间隔持久化）

    func currentRefreshInterval() -> Double {
        queue.sync { storedRefreshInterval }
    }

    func updateRefreshInterval(_ interval: Double) {
        queue.async { [self] in
            storedRefreshInterval = interval
            if let data = try? JSONEncoder().encode(interval) {
                try? data.write(to: refreshIntervalFile, options: .atomic)
            }
        }
    }
}

// MARK: - UsageState

/// 使用时长统计（按离电周期统计，充电时停止）
struct UsageState: Codable {
    var currentDischargeScreenOn: Int = 0
    var currentDischargeSleep: Int = 0
    var lastDischargeScreenOn: Int = 0
    var lastDischargeSleep: Int = 0
    var wasExternalConnected: Bool = false
    var lastPlugInTime: Date?
    var lastSavedAt: Date = Date()
}
