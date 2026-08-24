import Foundation
import Observation

/// 高级采样 Helper 生命周期状态；移除单列忙碌态，避免与安装混淆。
enum HelperLifecycleState: Equatable, Sendable {
    case disabled
    case starting
    case removing
    case enabled
    case needsUpdate
    case error(String)

    /// UI 短标签（纯映射，供状态行与测试断言使用）
    var label: String {
        switch self {
        case .disabled: return "已关闭"
        case .starting: return "启动中"
        case .removing: return "移除中"
        case .enabled: return "已启用"
        case .needsUpdate: return "需要更新"
        case .error: return "出错"
        }
    }

    /// 安装/更新和移除都是特权操作；进行中时 UI 必须禁止重复提交或反向操作。
    var isBusy: Bool {
        switch self {
        case .starting, .removing: true
        case .disabled, .enabled, .needsUpdate, .error: false
        }
    }
}

/// 启动时对磁盘 Helper 的只读检查结果。缺失与版本过旧必须区分：
/// 若 UserDefaults 残留开启但 Helper 已被外部删除，不得假装可以采样。
enum InstalledHelperState: Equatable, Sendable {
    case notInstalled
    case current
    case needsUpdate
}

/// Helper 生命周期可注入边界：生产实现包 BatteryReader（osascript / XPC / launchd），
/// 测试用 stub；本边界与 UserNotifications 无关，测试绝不触碰真实 Helper/launchd。
protocol HelperLifecycleOps: Sendable {
    /// 安装或更新 Helper；实现内部把阻塞操作移出调用线程
    func installOrUpdate() async -> Bool
    /// 显式卸载 Helper（唯一允许调用 uninstallHelper 的路径）
    func uninstall() async -> Bool
    /// 休眠态检查：区分缺失/当前/需更新（不建立 XPC、不触发 launchd）
    func installedHelperState() async -> InstalledHelperState
}

/// 生产实现：BatteryReader 的阻塞调用在 detached 任务执行，不阻塞主线程。
struct SystemHelperLifecycleOps: HelperLifecycleOps {
    let reader: BatteryReader

    func installOrUpdate() async -> Bool {
        await Task.detached(priority: .userInitiated) { reader.installHelperIfNeeded() }.value
    }

    func uninstall() async -> Bool {
        await Task.detached(priority: .userInitiated) { reader.uninstallHelper() }.value
    }

    func installedHelperState() async -> InstalledHelperState {
        await Task.detached(priority: .utility) {
            guard reader.isHelperInstalled() else { return .notInstalled }
            return reader.dormantInstalledHelperNeedsUpdate() ? .needsUpdate : .current
        }.value
    }
}

/// 高级采样「开关 → 安装/更新/卸载」状态机（@MainActor）。
///
/// 冻结语义：
/// - 开启只负责安装/更新成功后进入 enabled；安装失败、用户取消管理员授权或
///   XPC 错误时进入 error，调用方据此恢复真实关闭状态；
/// - disable 只把状态置为 disabled，绝不卸载、绝不请求管理员密码；
/// - 只有 remove() 是唯一显式卸载入口（对应设置页「移除辅助服务…」二次确认）。
@MainActor
@Observable
final class HelperLifecycleController {
    private let ops: any HelperLifecycleOps
    private(set) var state: HelperLifecycleState = .disabled
    private(set) var installedState: InstalledHelperState = .notInstalled
    private(set) var lastErrorMessage: String?
    /// 每次新的用户意图都会推进代际；await 返回的旧操作只能丢弃结果。
    private var operationGeneration: UInt64 = 0
    /// install/uninstall 涉及同一组系统文件和 launchd job，绝不允许重叠执行。
    private var privilegedOperationInFlight = false

    init(ops: any HelperLifecycleOps) {
        self.ops = ops
    }

    /// 启动时检查：只查询已安装 Helper 是否需要更新。不安装、不升级、绝不触发管理员授权。
    @discardableResult
    func refreshAtStartup(enabled: Bool) async -> HelperLifecycleState {
        let generation = operationGeneration
        let installedState = await ops.installedHelperState()
        // 用户在检查期间执行了开启/关闭/移除：启动旧结果不得覆盖新意图。
        guard generation == operationGeneration else { return state }
        self.installedState = installedState

        switch installedState {
        case .needsUpdate:
            state = .needsUpdate
            lastErrorMessage = "后台服务需要更新；再次开启高级采样时会请求管理员授权"
        case .notInstalled:
            state = .disabled
            lastErrorMessage = enabled ? "后台服务未安装；再次开启高级采样时会请求管理员授权" : nil
        case .current:
            state = enabled ? .enabled : .disabled
            lastErrorMessage = nil
        }
        return state
    }

    /// 开启高级采样：安装/更新 Helper。返回 false 表示安装失败或授权被取消，
    /// 调用方必须恢复真实关闭状态（不假装高级采样已开启）。
    func beginEnable() async -> Bool {
        guard !privilegedOperationInFlight else { return false }
        let generation = advanceGeneration()
        privilegedOperationInFlight = true
        state = .starting
        lastErrorMessage = nil
        let ok = await ops.installOrUpdate()
        privilegedOperationInFlight = false
        // 即使运行态意图已变化，成功安装的磁盘事实仍应如实保留。
        if ok { installedState = .current }
        // 例如安装授权期间用户已关闭：即使磁盘安装完成，也不得复活运行态。
        guard generation == operationGeneration else { return false }
        if ok {
            state = .enabled
        } else {
            state = .error("安装失败或已取消")
            lastErrorMessage = "安装后台服务失败，或被取消管理员授权；采样保持关闭"
        }
        return ok
    }

    /// 关闭高级采样：只停止采样并回到 disabled，绝不卸载 Helper。
    func setDisabled() {
        _ = advanceGeneration()
        state = .disabled
        lastErrorMessage = nil
    }

    /// 唯一显式卸载入口：只有用户确认「移除辅助服务…」后调用。
    @discardableResult
    func remove() async -> Bool {
        guard !privilegedOperationInFlight else { return false }
        let generation = advanceGeneration()
        privilegedOperationInFlight = true
        state = .removing
        lastErrorMessage = nil
        let ok = await ops.uninstall()
        privilegedOperationInFlight = false
        if ok { installedState = .notInstalled }
        guard generation == operationGeneration else { return false }
        if ok {
            state = .disabled
            lastErrorMessage = nil
        } else {
            state = .error("移除失败")
            lastErrorMessage = "移除后台服务失败，或被取消管理员授权"
        }
        return ok
    }

    @discardableResult
    private func advanceGeneration() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }
}

/// 分项读数回写门控（纯函数）：disable/stop 后迟到的异步/XPC 结果不得重新写回读数。
enum ComponentReadingGate {
    static func shouldApply(
        helperEnabled: Bool,
        lifecycleState: HelperLifecycleState,
        isStarted: Bool
    ) -> Bool {
        guard helperEnabled, isStarted else { return false }
        if case .enabled = lifecycleState { return true }
        return false
    }
}
