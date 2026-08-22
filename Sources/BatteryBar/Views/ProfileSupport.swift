import SwiftUI

/// Instruments 性能采样辅助。
///
/// 仅当 UserDefaults「BatteryBarProfileAutoScroll」为 true 时生效：
/// 启动后延迟数秒开始、以线性动画在页面顶/底锚点间连续滚动若干个来回，
/// 用于在无辅助功能权限的环境下驱动真实滚动，采集 SwiftUI/Animation Hitches 证据。
/// 默认关闭，不影响任何正常使用路径；「BatteryBarProfileSection」可在启动时
/// 指定初始页面（usage/power），供采样脚本切换页面。不新增任何持续动画或 blur。
enum ProfileSupport {
    static let topAnchorID = "profile-top"
    static let bottomAnchorID = "profile-bottom"

    static var autoScrollEnabled: Bool {
        UserDefaults.standard.bool(forKey: "BatteryBarProfileAutoScroll")
    }

    /// "usage" / "power"；nil 表示用户默认页面
    static var profileSection: String? {
        UserDefaults.standard.string(forKey: "BatteryBarProfileSection")
    }
}

enum ProfileAutoScroll {
    /// 延迟 idleDelay 秒（留出纯采样观察窗）后开始连续滚动，
    /// 共 cycles 个单程、每程 duration 秒；结束后静止。
    /// 必须在主线程调用（视图 onAppear）；用 MainActor Task 而非
    /// DispatchQueue.asyncAfter，避免跨隔离传递非 Sendable 的 ScrollViewProxy。
    @MainActor
    static func run(
        _ proxy: ScrollViewProxy,
        topID: String = ProfileSupport.topAnchorID,
        bottomID: String = ProfileSupport.bottomAnchorID,
        enabled: Bool = ProfileSupport.autoScrollEnabled,
        idleDelay: TimeInterval = 12,
        duration: TimeInterval = 6,
        cycles: Int = 8
    ) {
        guard enabled else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(idleDelay))
            var scrollDown = true
            for _ in 0..<max(0, cycles) {
                withAnimation(.linear(duration: duration)) {
                    proxy.scrollTo(scrollDown ? bottomID : topID)
                }
                try? await Task.sleep(for: .seconds(duration + 0.5))
                scrollDown.toggle()
            }
        }
    }
}

extension ProfileSupport {
    /// 采样脚本指定的初始页面；未配置时返回 nil（使用默认页）
    static var initialSection: AppSection? {
        switch profileSection {
        case "power": return .power
        case "cycles": return .cycles
        case "sync": return .sync
        case "usage": return .overview
        default: return nil
        }
    }
}
