import Testing
import Foundation
@testable import BatteryBar

/// snapshots.jsonl 追加日志：迁移、追加、坏行容忍、compact、dirty 语义。
/// 全部使用注入的临时目录，不触碰用户真实数据。
@Suite struct DataStoreJournalTests {

    private func makeStore() throws -> (store: DataStore, dir: URL, journal: URL, legacy: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryBarJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DataStore(directory: dir)
        return (store, dir,
                dir.appendingPathComponent("snapshots.jsonl"),
                dir.appendingPathComponent("snapshots.json"))
    }

    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snap(_ minutesAgo: Double, level: Double = 50, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: Date().addingTimeInterval(-minutesAgo * 60),
            level: level, isCharging: charging, wattage: 5.5,
            temperature: 0, screenOn: true
        )
    }

    @Test func legacyArrayMigratesToJournalWithoutDeletion() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        // 预置旧版全量数组文件
        let legacySnaps = [snap(120), snap(60), snap(10)]
        try JSONEncoder().encode(legacySnaps).write(to: ctx.legacy)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()

        #expect(store.allSnapshots().count == 3)
        // 迁移后 journal 存在且逐行可解码；旧文件作为回退副本保留
        #expect(FileManager.default.fileExists(atPath: ctx.journal.path))
        #expect(FileManager.default.fileExists(atPath: ctx.legacy.path))
        let lines = try String(contentsOf: ctx.journal, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            _ = try JSONDecoder().decode(BatterySnapshot.self, from: Data(line.utf8))
        }
    }

    @Test func saveAppendsSingleLineInsteadOfRewrite() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        store.saveSnapshot(snap(2))
        store.flushPendingWritesForTesting()
        #expect(try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n").count == 1)

        store.saveSnapshot(snap(1))
        store.flushPendingWritesForTesting()

        let text = try String(contentsOf: ctx.journal, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(store.allSnapshots().count == 2)
    }

    @Test func corruptTailLineSkippedOthersLoaded() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let a = snap(30), b = snap(20), c = snap(10)
        store.saveSnapshot(a); store.saveSnapshot(b); store.saveSnapshot(c)
        store.flushPendingWritesForTesting()

        // 模拟掉电：末尾追加半行
        let handle = try FileHandle(forWritingTo: ctx.journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"half-written".utf8))
        try handle.close()

        // 重新加载：跳过半行，保留 3 条完整历史
        let reloaded = DataStore(directory: ctx.dir)
        #expect(reloaded.allSnapshots().count == 3)
    }

    @Test func corruptMiddleLineSkippedHistoryStillLoads() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let a = snap(30), b = snap(20), c = snap(10)
        store.saveSnapshot(a); store.saveSnapshot(b); store.saveSnapshot(c)
        store.flushPendingWritesForTesting()

        // 中间插入一行垃圾（模拟局部损坏）
        let raw = try String(contentsOf: ctx.journal, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let corrupted = [lines[0], "{broken", lines[1], lines[2]].joined(separator: "\n") + "\n"
        try corrupted.write(to: ctx.journal, atomically: true, encoding: .utf8)

        let reloaded = DataStore(directory: ctx.dir)
        #expect(reloaded.allSnapshots().count == 3)
    }

    @Test func markSyncedCompactsAndPersistsDirtyFalse() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let a = snap(30), b = snap(20)
        store.saveSnapshot(a); store.saveSnapshot(b)
        store.flushPendingWritesForTesting()
        #expect(Set(store.dirtySnapshots().map(\.id)) == Set([a.id, b.id]))

        store.markSnapshotsSynced([a.id])
        store.flushPendingWritesForTesting()

        // compact 后内容一致且 dirty 状态已持久化
        #expect(store.dirtySnapshots().map(\.id) == [b.id])
        let reloaded = DataStore(directory: ctx.dir)
        #expect(reloaded.allSnapshots().count == 2)
        #expect(reloaded.dirtySnapshots().map(\.id) == [b.id])
        let byID = Dictionary(uniqueKeysWithValues: reloaded.allSnapshots().map { ($0.id, $0) })
        #expect(byID[a.id]?.dirty == false)
    }

    @Test func mergeRemoteKeepsNewerTimestampAndCompacts() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let local = snap(30, level: 40)
        store.saveSnapshot(local)
        store.flushPendingWritesForTesting()

        var remote = local
        remote.level = 38
        remote.timestamp = local.timestamp.addingTimeInterval(60)
        // SyncEngine.download 对远端快照统一置 dirty=false 后才合并
        remote.dirty = false
        store.mergeSnapshots([remote])
        store.flushPendingWritesForTesting()

        #expect(store.allSnapshots().count == 1)
        #expect(store.allSnapshots().first?.level == 38)
        // 远端合并的数据不应重新上传
        #expect(store.dirtySnapshots().isEmpty)
    }

    @Test func retentionTrimsBeyond24hOnLoadAndSave() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        // 直接写一份含超窗口数据的旧数组：加载时即裁剪
        let old = BatterySnapshot(timestamp: Date().addingTimeInterval(-48 * 3600), level: 90, isCharging: false, wattage: 5, temperature: 0, screenOn: true)
        let fresh = BatterySnapshot(timestamp: Date(), level: 50, isCharging: false, wattage: 5, temperature: 0, screenOn: true)
        try JSONEncoder().encode([old, fresh]).write(to: ctx.legacy)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()
        #expect(store.allSnapshots().count == 1)
        #expect(store.allSnapshots().first?.id == fresh.id)
    }
}
