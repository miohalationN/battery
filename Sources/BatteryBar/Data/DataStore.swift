import Foundation
import os

private let dataStoreLogger = Logger(subsystem: "com.batterybar", category: "DataStore")

extension Notification.Name {
    /// 快照数组真正完成内存更新与落盘后发送，图表无需再用每秒 tick 轮询。
    static let batterySnapshotsDidChange = Notification.Name("BatteryBarSnapshotsDidChange")
    /// 充放电周期新增或云端合并完成后发送。
    static let batteryCyclesDidChange = Notification.Name("BatteryBarCyclesDidChange")
}

/// JSON 文件持久化，替代 SwiftData
final class DataStore: @unchecked Sendable {
    static let shared = DataStore()

    private let baseDir: URL
    private let snapshotsFile: URL
    private let snapshotJournalFile: URL
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

    /// 生产环境使用 shared（默认 Application Support 目录）；
    /// 测试可注入临时目录隔离读写。
    init(directory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = directory ?? appSupport.appendingPathComponent("BatteryBar", isDirectory: true)
        snapshotsFile = baseDir.appendingPathComponent("snapshots.json")
        snapshotJournalFile = baseDir.appendingPathComponent("snapshots.jsonl")
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
            // 核心数据文件解码失败时先备份 .bak 再从空数据重建，
            // 避免格式损坏导致的数据静默丢失（MAINTENANCE_PLAN 回滚策略的落地）
            let journalSnapshots = loadSnapshotJournal()
            let loaded = journalSnapshots ?? loadJSON(from: snapshotsFile, backupOnFailure: true) ?? []
            snapshots = Self.retainedSnapshots(loaded, now: Date())
            // 第一次启动迁移旧数组文件；之后每条采样只追加一行。
            // 同时清掉超出保留窗口的旧记录与可能存在的末尾半行。
            if journalSnapshots == nil || snapshots.count != loaded.count {
                rewriteSnapshotJournal()
            }
            cycles = loadJSON(from: cyclesFile, backupOnFailure: true) ?? []
            syncConfig = loadJSON(from: configFile, backupOnFailure: true) ?? .default
        }
    }

    // MARK: - Snapshots

    func saveSnapshot(_ snap: BatterySnapshot) {
        queue.async { [self] in
            snapshots.append(snap)
            let retained = Self.retainedSnapshots(snapshots, now: snap.timestamp)
            if retained.count == snapshots.count {
                appendSnapshotToJournal(snap)
            } else {
                snapshots = retained
                rewriteSnapshotJournal()
            }
            postOnMain(.batterySnapshotsDidChange)
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
            rewriteSnapshotJournal()
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
            snapshots = Self.retainedSnapshots(
                byID.values.sorted { $0.timestamp < $1.timestamp },
                now: Date()
            )
            rewriteSnapshotJournal()
            postOnMain(.batterySnapshotsDidChange)
        }
    }

    // MARK: - Cycles

    func saveCycle(_ cycle: ChargeCycle) {
        queue.async { [self] in
            cycles.append(cycle)
            saveJSON(cycles, to: cyclesFile)
            postOnMain(.batteryCyclesDidChange)
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
            postOnMain(.batteryCyclesDidChange)
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

    /// 测试钩子：等待队列上已入队的写操作完成（单测验证 journal 落盘结果用）
    func flushPendingWritesForTesting() {
        queue.sync {}
    }

    // MARK: - JSON helpers

    /// 只保留时间窗口内的记录，并用硬上限防御异常高频或远端脏数据。
    static func retainedSnapshots(
        _ source: [BatterySnapshot],
        now: Date,
        hours: TimeInterval = 24,
        maxCount: Int = 1_500
    ) -> [BatterySnapshot] {
        guard maxCount > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let recent = source
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now.addingTimeInterval(300) }
            .sorted { $0.timestamp < $1.timestamp }
        return recent.count > maxCount ? Array(recent.suffix(maxCount)) : recent
    }

    private func loadSnapshotJournal() -> [BatterySnapshot]? {
        guard FileManager.default.fileExists(atPath: snapshotJournalFile.path),
              let data = try? Data(contentsOf: snapshotJournalFile) else { return nil }
        var decoded: [BatterySnapshot] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            do {
                decoded.append(try JSONDecoder().decode(BatterySnapshot.self, from: Data(line)))
            } catch {
                // 追加日志在掉电时最多留下末尾半行；跳过坏行，保留其余历史。
                dataStoreLogger.error("Skip corrupt snapshot journal line: \(error.localizedDescription, privacy: .public)")
            }
        }
        // 空日志（含全部行损坏）时回退 legacy：retainedSnapshots 会把过期记录滤掉，
        // 因此不会复活已被裁剪的数据；journal 有有效行时以其为准。
        if decoded.isEmpty, FileManager.default.fileExists(atPath: snapshotsFile.path) {
            dataStoreLogger.notice("Snapshot journal empty, falling back to legacy snapshots.json")
            return nil
        }
        return decoded
    }

    private func appendSnapshotToJournal(_ snapshot: BatterySnapshot) {
        do {
            var line = try JSONEncoder().encode(snapshot)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: snapshotJournalFile.path) {
                try line.write(to: snapshotJournalFile, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: snapshotJournalFile)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } catch {
            dataStoreLogger.error("Append snapshots.jsonl failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewriteSnapshotJournal() {
        do {
            let encoder = JSONEncoder()
            var data = Data()
            for snapshot in snapshots {
                data.append(try encoder.encode(snapshot))
                data.append(0x0A)
            }
            try data.write(to: snapshotJournalFile, options: .atomic)
        } catch {
            dataStoreLogger.error("Compact snapshots.jsonl failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadJSON<T: Decodable>(from url: URL, backupOnFailure: Bool = false) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            dataStoreLogger.error("Decode \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if backupOnFailure {
                let bakURL = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: bakURL)
                do {
                    try FileManager.default.moveItem(at: url, to: bakURL)
                    dataStoreLogger.info("Corrupt file backed up to \(bakURL.lastPathComponent, privacy: .public)")
                } catch {
                    dataStoreLogger.error("Backup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return nil
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            dataStoreLogger.error("Write \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postOnMain(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
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
