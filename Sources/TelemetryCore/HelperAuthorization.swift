import Foundation

/// Privileged Helper 的纯身份判定。签名有效性由 Security.framework 先验证；这里冻结
/// bundle id 与安装时绑定 CDHash 必须同时匹配的不可绕过规则，并提供无 root 单测面。
public enum HelperAuthorization {
    public static func allows(
        identifier: String?,
        actualCDHash: String?,
        expectedCDHash: String?
    ) -> Bool {
        guard identifier == "com.batterybar.app",
              let actual = actualCDHash?.lowercased(),
              let expected = expectedCDHash?.lowercased(),
              !actual.isEmpty,
              !expected.isEmpty else { return false }
        return actual == expected
    }
}
