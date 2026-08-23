import Testing
import Foundation
@testable import BatteryBar

/// SyncConfig 及枚举的 Codable / 默认值测试
@Suite struct SyncConfigTests {

    @Test func codableRoundTrip() throws {
        let config = SyncConfig(
            isEnabled: true,
            serverURL: "https://dav.example.com",
            username: "user@example.com",
            remotePath: "/BatteryBar",
            syncInterval: .min15,
            syncDirection: .uploadOnly,
            lastSyncAt: Date(timeIntervalSince1970: 1_720_780_800),
            deviceID: "test-device-id"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: data)

        #expect(decoded.isEnabled == config.isEnabled)
        #expect(decoded.serverURL == config.serverURL)
        #expect(decoded.username == config.username)
        #expect(decoded.remotePath == config.remotePath)
        #expect(decoded.syncInterval == config.syncInterval)
        #expect(decoded.syncDirection == config.syncDirection)
        #expect(decoded.lastSyncAt == config.lastSyncAt)
        #expect(decoded.deviceID == config.deviceID)
    }

    @Test func defaultConfigValues() {
        let config = SyncConfig.default

        #expect(config.isEnabled == false)
        // 默认服务器地址为坚果云 WebDAV（2026-07-14 起；此断言曾因 CI 测试失败不阻断而长期未被发现）
        #expect(config.serverURL == "https://dav.jianguoyun.com/dav/")
        #expect(config.remotePath == "/BatteryBar")
        #expect(config.syncInterval == .hour1)
        #expect(config.syncDirection == .bidirectional)
        #expect(config.lastSyncAt == nil)
        #expect(!config.deviceID.isEmpty)
    }

    @Test func webDAVCredentialIdentityIncludesOriginAndUsername() {
        let a = KeychainHelper.credentialAccount(
            serverURL: "https://DAV.example.com/path", username: "same-user"
        )
        let b = KeychainHelper.credentialAccount(
            serverURL: "https://other.example.com/path", username: "same-user"
        )
        let defaultPort = KeychainHelper.credentialAccount(
            serverURL: "https://dav.example.com:443/another", username: "same-user"
        )
        #expect(a == defaultPort)
        #expect(a != b)
    }

    @Test func syncIntervalSeconds() {
        #expect(SyncInterval.min15.seconds == 900)
        #expect(SyncInterval.hour1.seconds == 3600)
        #expect(SyncInterval.hour6.seconds == 21600)
        #expect(SyncInterval.manual.seconds == 0)
    }

    @Test func syncIntervalAllCasesCount() {
        #expect(SyncInterval.allCases.count == 4)
    }

    @Test func syncDirectionAllCasesCount() {
        #expect(SyncDirection.allCases.count == 3)
    }

    @Test func syncIntervalRawValuesStable() throws {
        // raw value 稳定以保证持久化兼容性
        for interval in SyncInterval.allCases {
            let data = try JSONEncoder().encode(interval)
            let decoded = try JSONDecoder().decode(SyncInterval.self, from: data)
            #expect(decoded == interval)
            #expect(decoded.rawValue == interval.rawValue)
        }
    }

    @Test func defaultConfigIsCodable() throws {
        // 默认配置（含设备 ID）应可往返编解码，不抛错
        let data = try JSONEncoder().encode(SyncConfig.default)
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: data)
        #expect(decoded.remotePath == SyncConfig.default.remotePath)
        #expect(decoded.syncInterval == SyncConfig.default.syncInterval)
    }

    @Test func webDAVTransportPolicyRequiresTLSOutsideLoopback() throws {
        try WebDAVEndpointPolicy.validate(#require(URL(string: "https://dav.example.com/root")))
        try WebDAVEndpointPolicy.validate(#require(URL(string: "http://localhost:8080/dav")))
        try WebDAVEndpointPolicy.validate(#require(URL(string: "http://127.0.0.1:8080/dav")))

        #expect(throws: WebDAVError.self) {
            try WebDAVEndpointPolicy.validate(#require(URL(string: "http://192.168.1.10/dav")))
        }
        #expect(throws: WebDAVError.self) {
            try WebDAVEndpointPolicy.validate(#require(URL(string: "dav.example.com")))
        }

        let source = try #require(URL(string: "https://dav.example.com/root"))
        #expect(WebDAVEndpointPolicy.allowsRedirect(
            from: source,
            to: try #require(URL(string: "https://dav.example.com/root/"))
        ))
        #expect(!WebDAVEndpointPolicy.allowsRedirect(
            from: source,
            to: try #require(URL(string: "https://attacker.example/root"))
        ))
        #expect(!WebDAVEndpointPolicy.allowsRedirect(
            from: source,
            to: try #require(URL(string: "http://dav.example.com/root"))
        ))
    }

    @Test @MainActor func scheduleFollowsEnabledAndIntervalChanges() {
        let engine = SyncEngine()
        var config = SyncConfig.default

        engine.applySchedule(config: config)
        #expect(engine.scheduledInterval == nil)

        config.isEnabled = true
        config.syncInterval = .hour1
        engine.applySchedule(config: config)
        #expect(engine.scheduledInterval == 3600)

        config.syncInterval = .min15
        engine.applySchedule(config: config)
        #expect(engine.scheduledInterval == 900)

        config.syncInterval = .manual
        engine.applySchedule(config: config)
        #expect(engine.scheduledInterval == nil)

        engine.stop()
    }

    @Test func disabledSyncCannotReportSuccess() async {
        let engine = SyncEngine()
        var config = SyncConfig.default
        config.isEnabled = false

        let completedAt = await engine.sync(config: config)
        #expect(completedAt == nil)
    }
}
