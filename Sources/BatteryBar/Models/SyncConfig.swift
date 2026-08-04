import Foundation
import IOKit

enum SyncInterval: String, Codable, CaseIterable {
    case min15, hour1, hour6, manual

    var seconds: TimeInterval {
        switch self {
        case .min15: 900
        case .hour1: 3600
        case .hour6: 21600
        case .manual: 0
        }
    }

    var label: String {
        switch self {
        case .min15: "每 15 分钟"
        case .hour1: "每小时"
        case .hour6: "每 6 小时"
        case .manual: "手动"
        }
    }
}

enum SyncDirection: String, Codable, CaseIterable {
    case bidirectional, uploadOnly, downloadOnly

    var label: String {
        switch self {
        case .bidirectional: "双向同步"
        case .uploadOnly: "仅上传"
        case .downloadOnly: "仅下载"
        }
    }
}

/// 同步配置
struct SyncConfig: Codable {
    var isEnabled: Bool
    var serverURL: String
    var username: String
    var remotePath: String
    var syncInterval: SyncInterval
    var syncDirection: SyncDirection
    var lastSyncAt: Date?
    var deviceID: String

    static let `default` = SyncConfig(
        isEnabled: false,
        serverURL: "https://dav.jianguoyun.com/dav/",
        username: "",
        remotePath: "/BatteryBar",
        syncInterval: .hour1,
        syncDirection: .bidirectional,
        lastSyncAt: nil,
        deviceID: Self.deviceIdentifier()
    )

    private static func deviceIdentifier() -> String {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0,
              let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        else { return UUID().uuidString }
        return uuid.takeRetainedValue() as? String ?? UUID().uuidString
    }
}
