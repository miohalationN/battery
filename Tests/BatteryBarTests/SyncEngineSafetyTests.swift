import Testing
import Foundation
@testable import BatteryBar

@Suite struct SyncEngineSafetyTests {
    private actor FakeWebDAVClient: WebDAVClientProtocol {
        enum ReadMode: Sendable {
            case notFound
            case fail(Int)
            case data(Data)
        }

        enum ListMode: Sendable {
            case files([WebDAVFile])
            case fail(Int)
        }

        var readMode: ReadMode
        var listMode: ListMode
        private var uploads: [(String, Data)] = []

        init(readMode: ReadMode = .notFound, listMode: ListMode = .files([])) {
            self.readMode = readMode
            self.listMode = listMode
        }

        func listFiles(at path: String) async throws -> [WebDAVFile] {
            switch listMode {
            case .files(let files): return files
            case .fail(let status): throw WebDAVError.httpStatus(status)
            }
        }

        func upload(data: Data, to path: String) async throws {
            uploads.append((path, data))
        }

        func download(from path: String) async throws -> Data {
            switch readMode {
            case .notFound: throw WebDAVError.notFound
            case .fail(let status): throw WebDAVError.httpStatus(status)
            case .data(let data): return data
            }
        }

        func createFolder(at path: String) async throws {}

        func uploadedPaths() -> [String] { uploads.map(\.0) }
        func uploadedBodies() -> [(String, Data)] { uploads }
    }

    private func makeStore() throws -> (DataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryBarSyncSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (DataStore(directory: dir), dir)
    }

    private func config(direction: SyncDirection = .uploadOnly) -> SyncConfig {
        SyncConfig(
            isEnabled: true,
            serverURL: "https://dav.example.com/root/",
            username: "reviewer",
            remotePath: "/BatteryBar",
            syncInterval: .manual,
            syncDirection: direction,
            lastSyncAt: nil,
            deviceID: "device-a"
        )
    }

    private func snapshot() -> BatterySnapshot {
        BatterySnapshot(
            timestamp: Date(), level: 70, isCharging: false, wattage: 8,
            temperature: 30, screenOn: true, batteryPower: 8,
            systemPowerAvailable: true, systemPowerIsEstimated: true,
            externalConnected: false
        )
    }

    @Test func existingRemoteReadFailureNeverFallsThroughToOverwrite() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let snap = snapshot()
        store.saveSnapshot(snap)
        store.flushPendingWritesForTesting()
        let fake = FakeWebDAVClient(readMode: .fail(503))
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        let uploadedPaths = await fake.uploadedPaths()

        #expect(completedAt == nil)
        #expect(uploadedPaths.isEmpty)
        #expect(store.dirtySnapshots().map(\.id) == [snap.id])
    }

    @Test func onlyExplicitNotFoundAllowsFirstUpload() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.saveSnapshot(snapshot())
        store.flushPendingWritesForTesting()
        let fake = FakeWebDAVClient(readMode: .notFound)
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        let uploadedPaths = await fake.uploadedPaths()
        #expect(completedAt != nil)
        #expect(uploadedPaths.contains { $0.hasSuffix(".jsonl.gz") })
        #expect(store.dirtySnapshots().isEmpty)
    }

    /// 远端同日文件部分行损坏：坏行隔离、好行保留、同步不整体中止。
    /// 每设备一文件的布局下（snapshots/<device>/<day>.jsonl.gz），坏行隔离 +
    /// 本地 dirty 上传是修复性覆盖：远端可解析行全部进入合并结果，
    /// 坏行被自然清除，不再因单行坏数据让该日同步永久失败。
    @Test func corruptRemoteLinesAreIsolatedAndGoodRowsSurvive() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = snapshot()
        store.saveSnapshot(local)
        store.flushPendingWritesForTesting()

        let remoteGood = BatterySnapshot(
            timestamp: Date().addingTimeInterval(-3600), level: 60, isCharging: false,
            wattage: 8, temperature: 30, screenOn: true, batteryPower: 8,
            systemPowerAvailable: true, systemPowerIsEstimated: true,
            externalConnected: false
        )
        let goodLine = String(data: try JSONSerialization.data(withJSONObject: remoteGood.toJSON()), encoding: .utf8)!
        let text = goodLine + "\n{not-json}\n"
        let corrupt = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
        let fake = FakeWebDAVClient(readMode: .data(corrupt))
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        #expect(completedAt != nil)

        let bodies = await fake.uploadedBodies()
        guard let (_, body) = bodies.first(where: { $0.0.hasSuffix(".jsonl.gz") }) else {
            Issue.record("snapshot file not uploaded")
            return
        }
        let inflated = try SyncEngine.boundedZlibDecompress(body, maximumBytes: 8 * 1_048_576)
        let merged = String(data: inflated, encoding: .utf8) ?? ""
        #expect(merged.contains(remoteGood.id.uuidString))     // 远端好行保留
        #expect(merged.contains(local.id.uuidString))         // 本地 dirty 上传
        #expect(!merged.contains("not-json"))                 // 坏行清除
        #expect(store.dirtySnapshots().isEmpty)                // 已标记同步
    }

    /// 远端 cycles 文件整体损坏：跳过 cycles 上传（仅上传本地子集会把已同步的
    /// 循环记录永久清掉，cycles 文件是累计型、无法行级隔离），保留本地
    /// dirty 待下次重试；快照同步不受影响。
    @Test func corruptRemoteCyclesFileSkipsCyclesUploadButSnapshotsSucceed() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.saveSnapshot(snapshot())
        store.saveCycle(ChargeCycle(
            startDate: Date().addingTimeInterval(-3_600), endDate: Date(),
            startLevel: 80, endLevel: 60, totalEnergy: 20, averageWattage: 8
        ))
        store.flushPendingWritesForTesting()
        let corrupt = try (Data("{not-json}".utf8) as NSData).compressed(using: .zlib) as Data
        let fake = FakeWebDAVClient(readMode: .data(corrupt))
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        let paths = await fake.uploadedPaths()
        #expect(completedAt != nil)                                    // 快照同步成功
        #expect(paths.contains { $0.hasSuffix(".jsonl.gz") })
        #expect(!paths.contains { $0.contains("/cycles/") })            // cycles 不上传
        #expect(store.dirtySnapshots().isEmpty)
        #expect(store.dirtyCycles().count == 1)                        // cycles 保留 dirty
    }

    @Test func failedDirectoryListingCannotReportSuccessfulDownload() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeWebDAVClient(listMode: .fail(503))
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config(direction: .downloadOnly))
        #expect(completedAt == nil)
    }

    @Test func cyclesUploadToPerDeviceFileNotSharedLegacyFile() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.saveCycle(ChargeCycle(
            startDate: Date().addingTimeInterval(-3_600), endDate: Date(),
            startLevel: 80, endLevel: 60, totalEnergy: 20, averageWattage: 8
        ))
        store.flushPendingWritesForTesting()
        let fake = FakeWebDAVClient(readMode: .notFound)
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        #expect(completedAt != nil)
        let paths = await fake.uploadedPaths()
        #expect(paths.contains("/BatteryBar/cycles/device-a.json"))
        #expect(!paths.contains("/BatteryBar/cycles/cycles.json"))
    }

    @Test func decompressionRejectsOutputBeyondBound() throws {
        let original = Data(repeating: 0x41, count: 4_096)
        let compressed = try (original as NSData).compressed(using: .zlib) as Data
        #expect(throws: WebDAVError.self) {
            _ = try SyncEngine.boundedZlibDecompress(compressed, maximumBytes: 128)
        }
    }

    @Test func malformedListingIsNotAcceptedAsEmptySuccess() {
        #expect(throws: WebDAVError.parseError) {
            _ = try WebDAVResponseParser.parseValidated(
                data: Data("<D:multistatus".utf8),
                baseURL: URL(string: "https://dav.example.com")!
            )
        }
    }
}
