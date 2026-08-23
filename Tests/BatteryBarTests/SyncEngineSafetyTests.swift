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

    @Test func corruptExistingRemoteFileIsNeverReplacedByLocalSubset() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.saveSnapshot(snapshot())
        store.flushPendingWritesForTesting()
        let corrupt = try (Data("{not-json}\n".utf8) as NSData).compressed(using: .zlib) as Data
        let fake = FakeWebDAVClient(readMode: .data(corrupt))
        let engine = SyncEngine(
            store: store,
            credentialProvider: { _, _ in "pw" },
            clientFactory: { _, _, _ in fake }
        )

        let completedAt = await engine.sync(config: config())
        let paths = await fake.uploadedPaths()
        #expect(completedAt == nil)
        #expect(paths.isEmpty)
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
