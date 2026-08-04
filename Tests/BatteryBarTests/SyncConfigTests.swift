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
        #expect(config.serverURL == "")
        #expect(config.remotePath == "/BatteryBar")
        #expect(config.syncInterval == .hour1)
        #expect(config.syncDirection == .bidirectional)
        #expect(config.lastSyncAt == nil)
        #expect(!config.deviceID.isEmpty)
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
}
