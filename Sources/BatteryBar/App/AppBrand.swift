import Foundation

/// 用户可见品牌与内部兼容标识分离。
///
/// 首次改名只改变显示名称；可执行文件、Bundle ID、数据目录、Keychain 与 Helper
/// 继续沿用 BatteryBar，确保现有安装无损升级且不重复请求管理员权限。
enum AppBrand {
    static let displayName = "电池监测"
    static let tagline = "电池与功耗记录"
}
