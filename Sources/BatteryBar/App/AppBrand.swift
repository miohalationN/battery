import Foundation

/// 用户可见品牌与内部兼容标识分离。
///
/// 集中式品牌定义（1.5.0 冻结）：
/// - displayName = BatteryArchive（产品正式英文名）
/// - shortName = BA（产品简称）
/// - localizedName = 电池档案（中文名）
/// - tagline = 电池健康与功耗记录（中文副标题）
///
/// 使用规则：关于页首次出现「BA · BatteryArchive」，下方补充
/// 「电池档案 · 电池健康与功耗记录」；设置、诊断、帮助和 README 可简称为 BA；
/// 不给普通指标和按钮机械添加 BA。版本 1.5.0 / build 6。
///
/// 兼容边界不变：可执行文件、bundle 文件名、Bundle ID、Helper/XPC/launchd、
/// 数据目录、UserDefaults、Keychain、WebDAV 路径与同步协议继续沿用
/// BatteryBar，保证现有安装无损升级。旧用户可见名「电池监测」已清理。
enum AppBrand {
    static let displayName = "BatteryArchive"
    static let shortName = "BA"
    static let localizedName = "电池档案"
    static let tagline = "电池健康与功耗记录"
    static let version = "1.5.0"
    static let build = "6"

    /// 关于页首行完整品牌：BA · BatteryArchive
    static let fullBrand = "\(shortName) · \(displayName)"
    /// 关于页第二行：中文名 · 副标题
    static let localizedFullBrand = "\(localizedName) · \(tagline)"
}