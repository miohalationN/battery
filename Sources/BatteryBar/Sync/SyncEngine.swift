import Foundation
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
    private let store = DataStore.shared
    private let syncLock = NSLock()
    private var isSyncing = false

    func start(config: SyncConfig) {
        guard config.isEnabled, config.syncInterval != .manual else { return }
        timer?.invalidate()
        let interval = config.syncInterval.seconds
        // 定时器回调中实时读取配置，避免用户修改配置后仍用旧值
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @Sendable [weak self] in
                guard let self else { return }
                let cfg = self.store.currentConfig()
                await self.sync(config: cfg)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sync(config: SyncConfig) async {
        // 并发保护：定时器触发的 sync 和手动"立即同步"可能并发，会导致远程数据损坏
        // NSLock 不能在 async 函数中直接使用，封装到同步方法里
        guard tryStartSyncing() else { return }
        defer { endSyncing() }

        guard config.isEnabled, !config.serverURL.isEmpty else { return }
        guard let password = KeychainHelper.getPassword(for: config.username) else {
            syncLogger.error("No password for \(config.username)")
            await publishState(.failed("未找到密码"))
            return
        }
        guard let serverURL = URL(string: config.serverURL) else {
            await publishState(.failed("服务器地址无效"))
            return
        }

        await publishState(.syncing)
        let client = WebDAVClient(baseURL: serverURL, username: config.username, password: password)

        do {
            try await ensureDirs(client: client, config: config)

            switch config.syncDirection {
            case .bidirectional, .uploadOnly:
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
        } catch {
            syncLogger.error("Sync failed: \(error.localizedDescription)")
            await publishState(.failed(error.localizedDescription))
        }
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

    private func upload(client: WebDAVClient, config: SyncConfig) async throws {
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
            if let existing = try? await client.download(from: path),
               let decompressed = try? (existing as NSData).decompressed(using: .zlib) as Data,
               let text = String(data: decompressed, encoding: .utf8) {
                var byID: [UUID: BatterySnapshot] = [:]
                for s in snaps { byID[s.id] = s }
                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let idStr = dict["id"] as? String,
                          let id = UUID(uuidString: idStr),
                          let ts = dict["ts"] as? Double
                    else { continue }
                    let remote = BatterySnapshot(
                        timestamp: Date(timeIntervalSince1970: ts),
                        level: dict["level"] as? Double ?? 0,
                        isCharging: dict["charging"] as? Bool ?? false,
                        wattage: dict["watt"] as? Double ?? 0,
                        temperature: dict["temp"] as? Double ?? 0,
                        screenOn: dict["screen"] as? Bool ?? false,
                        cpuPower: dict["cpu"] as? Double ?? 0,
                        gpuPower: dict["gpu"] as? Double ?? 0,
                        displayPower: dict["disp"] as? Double ?? 0,
                        dramPower: dict["dram"] as? Double ?? 0
                    )
                    if let local = byID[id] {
                        // timestamp 胜出
                        if remote.timestamp > local.timestamp { byID[id] = remote }
                    } else {
                        byID[id] = remote
                    }
                }
                merged = byID.values.sorted { $0.timestamp < $1.timestamp }
            } else {
                merged = snaps
            }

            let jsonl = merged.map { snap -> String in
                // toJSON 不会失败，但用 guard 替代 try! 更安全
                guard let data = try? JSONSerialization.data(withJSONObject: snap.toJSON()),
                      let str = String(data: data, encoding: .utf8) else { return "" }
                return str
            }.joined(separator: "\n") + "\n"

            let compressed = try (Data(jsonl.utf8) as NSData).compressed(using: .zlib) as Data
            try await client.upload(data: compressed, to: path)
        }

        let ids = Set(dirty.map(\.id))
        store.markSnapshotsSynced(ids)

        try await uploadCycles(client: client, config: config)
    }

    private func uploadCycles(client: WebDAVClient, config: SyncConfig) async throws {
        let dirtyCycles = store.dirtyCycles()
        guard !dirtyCycles.isEmpty else { return }
        let path = "\(config.remotePath)/cycles/cycles.json"
        // 先下载合并（startDate 胜出），避免覆盖他机已上传数据
        var mergedCycles: [ChargeCycle] = dirtyCycles
        if let data = try? await client.download(from: path),
           let remote = try? JSONDecoder().decode([ChargeCycle].self, from: data) {
            var byID: [UUID: ChargeCycle] = [:]
            for c in dirtyCycles { byID[c.id] = c }
            for c in remote {
                if let local = byID[c.id] {
                    if c.startDate > local.startDate { byID[c.id] = c }
                } else {
                    byID[c.id] = c
                }
            }
            mergedCycles = Array(byID.values)
        }
        let data = try JSONEncoder().encode(mergedCycles)
        try await client.upload(data: data, to: path)
        store.markCyclesSynced(Set(dirtyCycles.map(\.id)))
    }

    private func download(client: WebDAVClient, config: SyncConfig) async throws {
        // 每设备一文件布局：snapshots/ 下是各设备的子目录
        let snapshotDir = "\(config.remotePath)/snapshots/"
        guard let deviceDirs = try? await client.listFiles(at: snapshotDir) else { return }

        var allSnapshots: [BatterySnapshot] = []
        for deviceDir in deviceDirs where deviceDir.isDirectory {
            // 部分服务器会把请求目录自身列入结果，跳过它以避免重复列举
            if normalized(deviceDir.path) == normalized(snapshotDir) { continue }
            guard let files = try? await client.listFiles(at: deviceDir.path) else { continue }
            for file in files where file.name.hasSuffix(".jsonl.gz") {
                let data = try await client.download(from: file.path)
                guard let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data,
                      let text = String(data: decompressed, encoding: .utf8) else { continue }

                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let idStr = dict["id"] as? String,
                          let ts = dict["ts"] as? Double
                    else { continue }

                    var snap = BatterySnapshot(
                        timestamp: Date(timeIntervalSince1970: ts),
                        level: dict["level"] as? Double ?? 0,
                        isCharging: dict["charging"] as? Bool ?? false,
                        wattage: dict["watt"] as? Double ?? 0,
                        temperature: dict["temp"] as? Double ?? 0,
                        screenOn: dict["screen"] as? Bool ?? false,
                        cpuPower: dict["cpu"] as? Double ?? 0,
                        gpuPower: dict["gpu"] as? Double ?? 0,
                        displayPower: dict["disp"] as? Double ?? 0,
                        dramPower: dict["dram"] as? Double ?? 0
                    )
                    snap.id = UUID(uuidString: idStr) ?? snap.id
                    snap.dirty = false
                    allSnapshots.append(snap)
                }
            }
        }
        store.mergeSnapshots(allSnapshots)

        let cyclePath = "\(config.remotePath)/cycles/cycles.json"
        if let data = try? await client.download(from: cyclePath),
           let cycles = try? JSONDecoder().decode([ChargeCycle].self, from: data) {
            // 远程 cycles 解码时 dirty 默认为 false（见 ChargeCycle.init(from:)），
            // 避免下载后被误认为待上传，导致无限重传
            store.mergeCycles(cycles)
        }
    }

    private func ensureDirs(client: WebDAVClient, config: SyncConfig) async throws {
        // 根目录、snapshots/、cycles/
        for sub in ["", "snapshots", "cycles"] {
            let path = sub.isEmpty ? config.remotePath : "\(config.remotePath)/\(sub)"
            try? await client.createFolder(at: path)
        }
        // 本设备子目录：每设备一文件布局
        try? await client.createFolder(at: "\(config.remotePath)/snapshots/\(config.deviceID)")
    }

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 规范化路径用于比较：去掉首尾 `/`，便于把 `snapshots/` 自身条目从子目录列表中剔除。
    private func normalized(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        while p.hasSuffix("/") { p = String(p.dropLast()) }
        return p
    }
}
