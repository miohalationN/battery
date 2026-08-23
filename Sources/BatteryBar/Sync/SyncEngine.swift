import Foundation
import Compression
import os

private let syncLogger = Logger(subsystem: "com.batterybar", category: "Sync")

/// 同步状态，供 UI 观察
enum SyncState: Equatable {
    case idle
    case syncing
    case success(Date)
    case failed(String)
}

/// 同步引擎：本地优先，增量上传，每设备一文件（避免多设备同日数据互相覆盖）
final class SyncEngine: ObservableObject, @unchecked Sendable {
    @Published private(set) var state: SyncState = .idle

    private var timer: Timer?
    private let store: DataStore
    private let credentialProvider: @Sendable (String, String) -> String?
    private let clientFactory: @Sendable (URL, String, String) -> any WebDAVClientProtocol
    private let syncLock = NSLock()
    private var isSyncing = false

    private static let maximumDevices = 32
    private static let maximumFilesPerDevice = 4
    private static let maximumRemoteSnapshots = 5_000
    private static let maximumCycles = 5_000
    private static let maximumInflatedSnapshotBytes = 6 * 1_024 * 1_024

    init(
        store: DataStore = .shared,
        credentialProvider: @escaping @Sendable (String, String) -> String? = {
            KeychainHelper.getPassword(serverURL: $0, username: $1)
        },
        clientFactory: @escaping @Sendable (URL, String, String) -> any WebDAVClientProtocol = {
            WebDAVClient(baseURL: $0, username: $1, password: $2)
        }
    ) {
        self.store = store
        self.credentialProvider = credentialProvider
        self.clientFactory = clientFactory
    }

    /// 让运行中的调度器与最新配置保持一致。
    ///
    /// 每次启用状态或同步间隔变化时都先撤销旧 timer；这样从关闭切到开启会立即
    /// 建立调度，切到手动/关闭会停止调度，修改间隔也不会继续沿用启动时的周期。
    @MainActor
    func applySchedule(config: SyncConfig) {
        timer?.invalidate()
        timer = nil
        guard config.isEnabled, config.syncInterval != .manual else { return }
        let interval = config.syncInterval.seconds
        // 定时器回调中实时读取配置，避免用户修改配置后仍用旧值
        let nextTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @Sendable [weak self] in
                guard let self else { return }
                let cfg = self.store.currentConfig()
                await self.sync(config: cfg)
            }
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    @MainActor
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 成功时返回真实完成时间；任何校验失败、并发跳过或网络错误都返回 nil。
    /// 调用方只能用非 nil 值更新“上次同步”，禁止把尝试时间冒充成功时间。
    @discardableResult
    func sync(config: SyncConfig) async -> Date? {
        // 并发保护：定时器触发的 sync 和手动"立即同步"可能并发，会导致远程数据损坏
        // NSLock 不能在 async 函数中直接使用，封装到同步方法里
        guard tryStartSyncing() else { return nil }
        defer { endSyncing() }

        guard config.isEnabled, !config.serverURL.isEmpty else { return nil }
        guard let serverURL = URL(string: config.serverURL) else {
            await publishState(.failed("服务器地址无效"))
            return nil
        }
        do {
            try WebDAVEndpointPolicy.validate(serverURL)
        } catch {
            await publishState(.failed(error.localizedDescription))
            return nil
        }
        guard let password = credentialProvider(config.serverURL, config.username) else {
            syncLogger.error("No password for \(config.username)")
            await publishState(.failed("未找到密码"))
            return nil
        }

        await publishState(.syncing)
        let client = clientFactory(serverURL, config.username, password)

        do {
            switch config.syncDirection {
            case .bidirectional, .uploadOnly:
                try await ensureDirs(client: client, config: config)
                try await upload(client: client, config: config)
            case .downloadOnly: break
            }

            switch config.syncDirection {
            case .bidirectional, .downloadOnly:
                try await download(client: client, config: config)
            case .uploadOnly: break
            }

            let now = Date()
            // 只更新 lastSyncAt 字段，避免覆盖用户在同步期间修改的其他配置（TOCTOU）
            store.updateLastSyncAt(now)
            syncLogger.info("Sync done at \(now.description)")
            await publishState(.success(now))
            return now
        } catch {
            syncLogger.error("Sync failed: \(error.localizedDescription)")
            await publishState(.failed(error.localizedDescription))
            return nil
        }
    }

    /// 供状态页与回归测试确认当前实际调度周期，不暴露 Timer 本身。
    @MainActor
    var scheduledInterval: TimeInterval? {
        timer?.timeInterval
    }

    @MainActor
    private func publishState(_ s: SyncState) {
        state = s
    }

    /// 尝试进入同步状态：若已有同步在跑则返回 false。
    /// 把 NSLock 操作封装在同步函数中，因为 NSLock.lock/unlock 不能从 async 上下文直接调用。
    private func tryStartSyncing() -> Bool {
        syncLock.lock()
        defer { syncLock.unlock() }
        if isSyncing { return false }
        isSyncing = true
        return true
    }

    private func endSyncing() {
        syncLock.lock()
        isSyncing = false
        syncLock.unlock()
    }

    private func upload(client: any WebDAVClientProtocol, config: SyncConfig) async throws {
        let dirty = store.dirtySnapshots()
        guard !dirty.isEmpty else {
            // 没有 dirty snapshots 也要尝试上传 cycles
            try await uploadCycles(client: client, config: config)
            return
        }

        let grouped = Dictionary(grouping: dirty) { dayKey($0.timestamp) }
        for (day, snaps) in grouped {
            // 每设备一文件：不同 Mac 写入各自目录，避免同日数据互相覆盖
            let path = "\(config.remotePath)/snapshots/\(config.deviceID)/\(day).jsonl.gz"

            // 先下载云端已有同日文件，与本地 dirty 合并（timestamp 胜出），避免覆盖丢失
            var merged: [BatterySnapshot]
            do {
                let existing = try await client.download(from: path)
                let decompressed = try Self.boundedZlibDecompress(
                    existing,
                    maximumBytes: Self.maximumInflatedSnapshotBytes
                )
                guard let text = String(data: decompressed, encoding: .utf8) else {
                    throw WebDAVError.parseError
                }
                var byID: [UUID: BatterySnapshot] = [:]
                for s in snaps { byID[s.id] = s }
                let lines = text.split(separator: "\n")
                guard lines.count <= Self.maximumRemoteSnapshots else {
                    throw WebDAVError.tooManyEntries
                }
                for line in lines {
                    guard let lineData = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let remote = BatterySnapshot.from(remoteJSON: dict)
                    else { throw WebDAVError.parseError }
                    if let local = byID[remote.id] {
                        // timestamp 胜出
                        if remote.timestamp > local.timestamp { byID[remote.id] = remote }
                    } else {
                        byID[remote.id] = remote
                    }
                }
                merged = byID.values.sorted { $0.timestamp < $1.timestamp }
            } catch WebDAVError.notFound {
                merged = snaps
            }

            let jsonl = try merged.map { snap -> String in
                let data = try JSONSerialization.data(withJSONObject: snap.toJSON())
                guard let str = String(data: data, encoding: .utf8) else {
                    throw WebDAVError.parseError
                }
                return str
            }.joined(separator: "\n") + "\n"

            let compressed = try (Data(jsonl.utf8) as NSData).compressed(using: .zlib) as Data
            try await client.upload(data: compressed, to: path)
        }

        let ids = Set(dirty.map(\.id))
        store.markSnapshotsSynced(ids)

        try await uploadCycles(client: client, config: config)
    }

    private func uploadCycles(client: any WebDAVClientProtocol, config: SyncConfig) async throws {
        let dirtyCycles = store.dirtyCycles()
        guard !dirtyCycles.isEmpty else { return }
        // v2 布局：每设备独立文件。旧共享 cycles.json 只读迁移，永不再覆盖写。
        let path = "\(config.remotePath)/cycles/\(config.deviceID).json"
        var mergedCycles: [ChargeCycle] = dirtyCycles
        do {
            let data = try await client.download(from: path)
            let remote = try JSONDecoder().decode([ChargeCycle].self, from: data)
            guard remote.count <= Self.maximumCycles else { throw WebDAVError.tooManyEntries }
            var byID: [UUID: ChargeCycle] = [:]
            for c in dirtyCycles { byID[c.id] = c }
            for c in remote {
                if let local = byID[c.id] {
                    if c.startDate > local.startDate { byID[c.id] = c }
                } else {
                    byID[c.id] = c
                }
            }
            mergedCycles = byID.values.sorted { $0.startDate < $1.startDate }
        } catch WebDAVError.notFound {
            // 首次上传该设备文件。
        }
        guard mergedCycles.count <= Self.maximumCycles else { throw WebDAVError.tooManyEntries }
        let data = try JSONEncoder().encode(mergedCycles)
        try await client.upload(data: data, to: path)
        store.markCyclesSynced(Set(dirtyCycles.map(\.id)))
    }

    private func download(client: any WebDAVClientProtocol, config: SyncConfig) async throws {
        // 每设备一文件布局：snapshots/ 下是各设备的子目录
        let snapshotDir = "\(config.remotePath)/snapshots/"
        let listedDeviceDirs: [WebDAVFile]
        do {
            listedDeviceDirs = try await client.listFiles(at: snapshotDir)
        } catch WebDAVError.notFound {
            listedDeviceDirs = []
        }
        let deviceDirs = listedDeviceDirs.filter { $0.isDirectory }
        guard deviceDirs.count <= Self.maximumDevices + 1 else { throw WebDAVError.tooManyEntries }

        var snapshotsByID: [UUID: BatterySnapshot] = [:]
        for deviceDir in deviceDirs {
            // 部分服务器会把请求目录自身列入结果，跳过它以避免重复列举
            if normalized(deviceDir.path) == normalized(snapshotDir) { continue }
            let files = try await client.listFiles(at: deviceDir.path)
            let recentFiles = files.filter { !$0.isDirectory && isRelevantSnapshotFile($0.name) }
            guard recentFiles.count <= Self.maximumFilesPerDevice else { throw WebDAVError.tooManyEntries }
            for file in recentFiles {
                let data = try await client.download(from: file.path)
                let decompressed = try Self.boundedZlibDecompress(
                    data,
                    maximumBytes: Self.maximumInflatedSnapshotBytes
                )
                guard let text = String(data: decompressed, encoding: .utf8) else {
                    throw WebDAVError.parseError
                }

                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let snap = BatterySnapshot.from(remoteJSON: dict)
                    else { throw WebDAVError.parseError }
                    if let existing = snapshotsByID[snap.id] {
                        if snap.timestamp > existing.timestamp { snapshotsByID[snap.id] = snap }
                    } else {
                        snapshotsByID[snap.id] = snap
                    }
                }
                if snapshotsByID.count > Self.maximumRemoteSnapshots {
                    snapshotsByID = Dictionary(
                        uniqueKeysWithValues: snapshotsByID.values
                            .sorted { $0.timestamp > $1.timestamp }
                            .prefix(Self.maximumRemoteSnapshots)
                            .map { ($0.id, $0) }
                    )
                }
            }
        }
        store.mergeSnapshots(Array(snapshotsByID.values))

        let cycleDir = "\(config.remotePath)/cycles/"
        let cycleFiles: [WebDAVFile]
        do {
            cycleFiles = try await client.listFiles(at: cycleDir)
        } catch WebDAVError.notFound {
            cycleFiles = []
        }
        let jsonFiles = cycleFiles.filter { !$0.isDirectory && $0.name.hasSuffix(".json") }
        guard jsonFiles.count <= Self.maximumDevices + 1 else { throw WebDAVError.tooManyEntries }
        var cyclesByID: [UUID: ChargeCycle] = [:]
        for file in jsonFiles {
            let data = try await client.download(from: file.path)
            let decoded = try JSONDecoder().decode([ChargeCycle].self, from: data)
            guard decoded.count <= Self.maximumCycles else { throw WebDAVError.tooManyEntries }
            for cycle in decoded {
                if let existing = cyclesByID[cycle.id] {
                    if cycle.startDate > existing.startDate { cyclesByID[cycle.id] = cycle }
                } else {
                    cyclesByID[cycle.id] = cycle
                }
            }
            guard cyclesByID.count <= Self.maximumCycles else { throw WebDAVError.tooManyEntries }
        }
        store.mergeCycles(Array(cyclesByID.values))
    }

    private func ensureDirs(client: any WebDAVClientProtocol, config: SyncConfig) async throws {
        // 根目录、snapshots/、cycles/
        for sub in ["", "snapshots", "cycles"] {
            let path = sub.isEmpty ? config.remotePath : "\(config.remotePath)/\(sub)"
            try await client.createFolder(at: path)
        }
        // 本设备子目录：每设备一文件布局
        try await client.createFolder(at: "\(config.remotePath)/snapshots/\(config.deviceID)")
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 本地只保留 24 小时，远端最多需要今天、昨天以及一个未来时钟容忍日。
    private func isRelevantSnapshotFile(_ name: String, now: Date = Date()) -> Bool {
        guard name.hasSuffix(".jsonl.gz") else { return false }
        let stem = String(name.dropLast(".jsonl.gz".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: stem) else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let lower = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let upper = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now))!
        return day >= lower && day < upper
    }

    /// 一次性解压到固定上限缓冲区。达到缓冲区末端视为截断并拒绝，避免 zip bomb。
    static func boundedZlibDecompress(_ data: Data, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, !data.isEmpty else { throw WebDAVError.parseError }
        var output = Data(count: maximumBytes + 1)
        let decodedSize = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    outputBuffer.count,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    inputBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize > 0 else { throw WebDAVError.parseError }
        guard decodedSize <= maximumBytes else { throw WebDAVError.decompressedDataTooLarge }
        output.count = decodedSize
        return output
    }

    /// 规范化路径用于比较：去掉首尾 `/`，便于把 `snapshots/` 自身条目从子目录列表中剔除。
    private func normalized(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        while p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }
}
