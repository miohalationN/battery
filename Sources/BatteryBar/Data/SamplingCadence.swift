import Foundation

/// 实时读数的可见界面来源。主窗口与菜单栏弹窗可以同时存在，必须分别登记，
/// 避免关闭其中一个时误把仍可见的另一个也降到后台频率。
enum LiveReadingSurface: Hashable {
    case mainWindow
    case statusPopover
}

/// 采样节奏的纯策略，集中冻结界面设置、后台保活与高级分项采样的边界。
enum SamplingCadence {
    static let minimumForegroundInterval: TimeInterval = 1
    static let maximumForegroundInterval: TimeInterval = 30
    /// 无读数界面可见时，仅维持菜单栏状态、通知与插拔检测。
    static let backgroundInterval: TimeInterval = 15
    /// Helper 内的 powermetrics 同样每 10 秒产出一轮；独立于基础读数设置。
    static let componentPowerInterval: TimeInterval = 10
    static let historyInterval: TimeInterval = 60

    static func sanitizedForegroundInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return minimumForegroundInterval }
        return min(maximumForegroundInterval, max(minimumForegroundInterval, value))
    }

    static func effectiveInterval(
        foregroundInterval: TimeInterval,
        hasVisibleSurface: Bool
    ) -> TimeInterval {
        hasVisibleSurface
            ? sanitizedForegroundInterval(foregroundInterval)
            : backgroundInterval
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
