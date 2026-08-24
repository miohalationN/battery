import Foundation

/// 实时读数的可见界面来源。主窗口与菜单栏弹窗可以同时存在，必须分别登记，
/// 避免关闭其中一个时误把仍可见的另一个也降到后台频率。
enum LiveReadingSurface: Hashable {
    case mainWindow
    case statusPopover
}

/// 固定采样节奏的纯策略（冻结口径，不提供用户可调刷新频率）：
/// - 任一读数界面可见：基础兜底读取每 5 秒；
/// - 都不可见：每 15 秒保活（状态栏、通知、插拔检测）；
/// - 每次界面打开立即读取一次（由 PowerSampler 在可见性切换时触发）；
/// - 历史窗口每 60 秒落盘；Helper/powermetrics 独立每 10 秒。
/// IORegistry 功率、温度没有可靠公开逐字段通知，因此保留兜底轮询，
/// 不能宣称完全事件驱动；系统驱动可能数秒至十余秒才发布新值。
enum SamplingCadence {
    /// 读数界面可见时的基础兜底间隔
    static let foregroundInterval: TimeInterval = 5
    /// 无读数界面可见时的保活间隔
    static let backgroundInterval: TimeInterval = 15
    /// Helper 内 powermetrics 的独立产出节奏
    static let componentPowerInterval: TimeInterval = 10
    /// 历史快照落盘节奏
    static let historyInterval: TimeInterval = 60
    /// 通知风暴合并窗口（约 100–250ms）
    static let notificationCoalesceWindow: TimeInterval = 0.18

    static func effectiveInterval(hasVisibleSurface: Bool) -> TimeInterval {
        hasVisibleSurface ? foregroundInterval : backgroundInterval
    }
}

/// 多界面需求协调器。重复的 appear/disappear 幂等，最后一个界面关闭后才降频。
struct LiveReadingDemand {
    private(set) var surfaces: Set<LiveReadingSurface> = []

    var hasVisibleSurface: Bool { !surfaces.isEmpty }

    @discardableResult
    mutating func set(_ surface: LiveReadingSurface, visible: Bool) -> Bool {
        if visible {
            return surfaces.insert(surface).inserted
        }
        return surfaces.remove(surface) != nil
    }
}

/// 系统事件（IOPS / 低电量模式 / 热压力）的通知风暴合并决策——纯逻辑、时间注入。
///
/// 规则：
/// - 距上次触发不足合并窗口：不立即触发，返回需要等待的剩余时长（延迟触发）；
/// - 已有延迟触发待执行时，后续事件全部并入（返回 nil）；
/// - 其余情况立即触发。
/// 触发完成后必须调用 `fireCompleted` 记账，保证下一轮事件能重新获得调度。
struct NotificationCoalescer {
    let coalesceWindow: TimeInterval
    private(set) var lastFireAt: Date?
    private(set) var pendingSince: Date?

    init(coalesceWindow: TimeInterval = SamplingCadence.notificationCoalesceWindow) {
        self.coalesceWindow = coalesceWindow
    }

    enum Decision: Equatable {
        /// 立即执行读取
        case fireNow
        /// 并入已在等待的触发，不做任何事
        case mergeIntoPending
        /// 延迟指定秒数后执行一次读取
        case delay(TimeInterval)
    }

    mutating func eventReceived(now: Date) -> Decision {
        if pendingSince != nil { return .mergeIntoPending }
        if let last = lastFireAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < coalesceWindow {
                pendingSince = now
                return .delay(coalesceWindow - elapsed)
            }
            if elapsed < 0 {
                // 时钟回拨：按立即触发处理并重置基准
                lastFireAt = now
                return .fireNow
            }
        }
        lastFireAt = now
        return .fireNow
    }

    mutating func fireCompleted(at date: Date) {
        lastFireAt = date
        pendingSince = nil
    }
}
