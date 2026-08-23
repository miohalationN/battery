import Foundation
import Security

/// Keychain 读写封装
enum KeychainHelper {
    private static let service = "com.batterybar.webdav.v2"
    private static let legacyService = "com.batterybar.webdav"
    private static let legacyMigrationKey = "BatteryBarWebDAVCredentialMigrationV2Completed"

    static func setPassword(_ password: String, serverURL: String, username: String) throws {
        guard let data = password.data(using: .utf8) else { return }
        let account = credentialAccount(serverURL: serverURL, username: username)

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.saveFailed(updateStatus) }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // AfterFirstUnlock：首次解锁后即可访问，适合后台同步任务（锁屏时仍可读取）
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func getPassword(
        serverURL: String,
        username: String,
        allowLegacyMigration: Bool = false
    ) -> String? {
        let account = credentialAccount(serverURL: serverURL, username: username)
        if let current = password(service: service, account: account) {
            if allowLegacyMigration {
                UserDefaults.standard.set(true, forKey: legacyMigrationKey)
            }
            return current
        }

        // v1 只以用户名为 account。首次读取时复制到“源站 + 用户名”的 v2 身份；
        // 只能由设置页首次载入既有配置时显式允许。普通查找绝不能把旧密码自动
        // 带到用户刚输入的另一个源站。保留旧项用于回滚，不做破坏性删除。
        guard allowLegacyMigration,
              !UserDefaults.standard.bool(forKey: legacyMigrationKey) else { return nil }
        guard let legacy = password(service: legacyService, account: username) else { return nil }
        do {
            try setPassword(legacy, serverURL: serverURL, username: username)
            UserDefaults.standard.set(true, forKey: legacyMigrationKey)
        } catch {
            return nil
        }
        return legacy
    }

    private static func password(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(serverURL: String, username: String) {
        let account = credentialAccount(serverURL: serverURL, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func credentialAccount(serverURL: String, username: String) -> String {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: serverURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return "\(serverURL.trimmingCharacters(in: .whitespacesAndNewlines))|\(trimmedUser)"
        }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = url.port ?? defaultPort
        let origin = port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
        return "\(origin)|\(trimmedUser)"
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }
}
