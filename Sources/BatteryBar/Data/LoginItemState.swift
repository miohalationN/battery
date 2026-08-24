import Foundation
import Observation
import ServiceManagement

/// SMAppService 登录项状态。requiresApproval 表示已请求但用户尚未在
/// 系统设置中允许——此时不得假装已开启。
enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

/// 可注入的 SMAppService 封装：右键菜单与「应用设置」Toggle 共用同一状态来源，
/// 禁止两套逻辑漂移。
protocol LoginItemControlling: Sendable {
    func currentStatus() -> LoginItemStatus
    func register() throws
    func unregister() throws
    func openApprovalSettings()
}

struct SystemLoginItemController: LoginItemControlling {
    func currentStatus() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 打开系统设置的登录项面板（requiresApproval 时引导用户允许）。
    /// 优先使用官方 API；回退到 Login Items 设置扩展 URL。
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 登录项共享状态模型（主线程）。默认不替用户开启：
/// 初始 status 由 refresh() 从系统读取，保持与现有注册状态一致。
@MainActor
@Observable
final class LoginItemState {
    private let controller: any LoginItemControlling
    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var lastErrorMessage: String?

    init(controller: any LoginItemControlling = SystemLoginItemController()) {
        self.controller = controller
        // 初始状态必须与真实系统注册状态一致，不替用户开启
        status = controller.currentStatus()
    }

    var isOn: Bool { status == .enabled }
    /// 已请求注册但等待用户在系统设置中允许
    var needsApproval: Bool { status == .requiresApproval }

    var statusSubtitle: String {
        switch status {
        case .enabled: "已在登录项中启用"
        case .notRegistered: "关闭"
        case .requiresApproval: "需要在系统设置中允许"
        // .notFound（BTM 无记录）不等于永久不支持：首次安装未注册即此状态，
        // 展示为未注册并允许用户开启；不要把它当环境错误禁用开关。
        case .notFound: "关闭（尚未注册）"
        }
    }

    /// 从系统读取真实状态：页面重新出现、应用重新激活后都应调用
    func refresh() {
        status = controller.currentStatus()
    }

    /// 打开系统设置的登录项面板（requiresApproval 时引导用户允许）
    func openApprovalSettings() {
        controller.openApprovalSettings()
    }

    /// 开关动作封装。register/unregister 失败时刷新为真实系统状态并返回
    /// 可理解的错误文案；成功返回 nil。
    @discardableResult
    func setEnabled(_ target: Bool) -> String? {
        defer { refresh() }
        do {
            if target {
                try controller.register()
            } else {
                try controller.unregister()
            }
            lastErrorMessage = nil
            return nil
        } catch {
            let message = Self.describe(error, target: target)
            lastErrorMessage = message
            return message
        }
    }

    static func describe(_ error: Error, target: Bool) -> String {
        let action = target ? "开启" : "关闭"
        return "\(action)开机自启动失败：\(error.localizedDescription)"
    }
}
