import Foundation
import UserNotifications
import os

private let notifLogger = Logger(subsystem: "com.batterybar", category: "Notification")

/// 系统通知授权状态（UNAuthorizationStatus 的领域映射）
enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        @unknown default: self = .notDetermined
        }
    }
}

/// 系统通知授权边界（可注入；测试用 stub，绝不请求真实权限）。
protocol NotificationAuthorizing: Sendable {
    func currentAuthorization() async -> NotificationAuthorization
    func requestAuthorization() async -> Bool
}

struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func currentAuthorization() async -> NotificationAuthorization {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let state = NotificationAuthorization(settings.authorizationStatus)
                continuation.resume(returning: state)
            }
        }
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    notifLogger.error("Notification permission error: \(error.localizedDescription)")
                }
                continuation.resume(returning: granted)
            }
        }
    }
}

/// 通知管理器。
///
/// 权限与触发策略冻结语义：
/// - 启动、创建本管理器、读取电量都不请求通知权限；
/// - 只有用户在设置页主动开启某个提醒开关且授权状态为 notDetermined 时才请求；
/// - 首次初始化按授权状态推导默认开关：authorized/provisional 视为旧用户两开关均开；
///   notDetermined/denied 两开关均关；并写入版本化 initialized 标记，之后不覆盖用户选择；
/// - 授权 denied 时开关恢复真实关闭状态并给出原因与系统设置入口；
/// - 低电量/充满的触发门槛与冷却窗口由 NotificationPolicy（纯逻辑）裁决，
///   冷却时间戳持久化到 UserDefaults，BA 重启后依然有效。
@MainActor
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private enum Key {
        /// 版本化 initialized 标记：写入后不得再按授权状态推导默认值
        static let initialized = "BatteryBarNotificationInitialized"
        static let lowBattery = "BatteryBarNotifyLowBattery"
        static let fullCharge = "BatteryBarNotifyFullCharge"
        static let lastLowBattery = "BatteryBarLastLowBatteryNotifAt"
        static let lastFullCharge = "BatteryBarLastFullChargeNotifAt"
    }

    /// 首个 initialized 版本；未来策略变更可提升版本做迁移
    private static let initializedVersion = "1"

    private let authorizer: any NotificationAuthorizing
    private let defaults: UserDefaults

    private(set) var authorizationState: NotificationAuthorization = .notDetermined

    /// 低电量提醒开关（真实持久化状态）
    private(set) var lowBatteryEnabled: Bool = false
    /// 充满提醒开关（真实持久化状态）
    private(set) var fullChargeEnabled: Bool = false
    /// 开启失败/权限被拒时的简洁原因
    private(set) var lastErrorMessage: String?

    /// 通知权限当前是否有效（可作为触发门槛）
    var permissionValid: Bool {
        switch authorizationState {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        }
    }

    /// 上次低电量通知时间（持久化冷却依据）
    var lastLowBatteryNotificationAt: Date? {
        defaults.object(forKey: Key.lastLowBattery) as? Date
    }
    /// 上次充满通知时间（持久化冷却依据）
    var lastFullChargeNotificationAt: Date? {
        defaults.object(forKey: Key.lastFullCharge) as? Date
    }

    init(
        authorizer: any NotificationAuthorizing = SystemNotificationAuthorizer(),
        defaults: UserDefaults = .standard
    ) {
        self.authorizer = authorizer
        self.defaults = defaults
        super.init()
        UNUserNotificationCenter.current().delegate = self

        // 已初始化的用户：读取持久化的用户选择，绝不主动请求权限
        if defaults.object(forKey: Key.initialized) != nil {
            lowBatteryEnabled = defaults.bool(forKey: Key.lowBattery)
            fullChargeEnabled = defaults.bool(forKey: Key.fullCharge)
        }
    }

    /// 启动时调用：只查询授权状态，绝不请求权限。
    /// 首次初始化按授权状态推导默认开关并写入版本化标记；
    /// 之后只刷新授权状态（denied 时把残留的开启选择恢复为真实关闭）。
    func start() async {
        guard defaults.object(forKey: Key.initialized) == nil else {
            await refreshAuthorization()
            return
        }
        let state = await authorizer.currentAuthorization()
        authorizationState = state
        // old user（已授权/临时授权）：维持旧行为，两开关默认开启
        let legacy = state == .authorized || state == .provisional
        lowBatteryEnabled = legacy
        fullChargeEnabled = legacy
        defaults.set(Self.initializedVersion, forKey: Key.initialized)
        defaults.set(lowBatteryEnabled, forKey: Key.lowBattery)
        defaults.set(fullChargeEnabled, forKey: Key.fullCharge)
        notifLogger.info("Notification settings initialized, state=\(String(describing: state))")
    }

    /// 刷新授权状态：系统设置中用户权限变化后调用。
    /// 授权被拒绝时把开关恢复为真实关闭状态，不假装已开启。
    func refreshAuthorization() async {
        let state = await authorizer.currentAuthorization()
        authorizationState = state
        if state == .denied {
            if lowBatteryEnabled {
                lowBatteryEnabled = false
                defaults.set(false, forKey: Key.lowBattery)
            }
            if fullChargeEnabled {
                fullChargeEnabled = false
                defaults.set(false, forKey: Key.fullCharge)
            }
            lastErrorMessage = "系统通知权限已被拒绝，请在系统设置中允许后重试"
        }
    }

    /// 用户主动切换低电量提醒。
    /// 只有授权为 notDetermined 时才请求系统权限；请求被拒或已 denied 时开关保持关闭。
    func setLowBatteryEnabled(_ on: Bool) async {
        lastErrorMessage = nil
        guard on else {
            applyLowBattery(false)
            return
        }
        switch authorizationState {
        case .denied:
            // 不假装已经开启：保持真实关闭并给出系统设置入口
            lastErrorMessage = "系统通知权限被拒绝，无法开启低电量提醒；请在系统设置中允许后重试"
        case .notDetermined:
            let granted = await authorizer.requestAuthorization()
            if granted {
                authorizationState = await authorizer.currentAuthorization()
                applyLowBattery(true)
            } else {
                authorizationState = .denied
                lastErrorMessage = "未获得系统通知权限，低电量提醒保持关闭"
            }
        default:
            applyLowBattery(true)
        }
    }

    /// 用户主动切换充满提醒。规则同 setLowBatteryEnabled。
    func setFullChargeEnabled(_ on: Bool) async {
        lastErrorMessage = nil
        guard on else {
            applyFullCharge(false)
            return
        }
        switch authorizationState {
        case .denied:
            lastErrorMessage = "系统通知权限被拒绝，无法开启充满提醒；请在系统设置中允许后重试"
        case .notDetermined:
            let granted = await authorizer.requestAuthorization()
            if granted {
                authorizationState = await authorizer.currentAuthorization()
                applyFullCharge(true)
            } else {
                authorizationState = .denied
                lastErrorMessage = "未获得系统通知权限，充满提醒保持关闭"
            }
        default:
            applyFullCharge(true)
        }
    }

    private func applyLowBattery(_ on: Bool) {
        lowBatteryEnabled = on
        defaults.set(on, forKey: Key.lowBattery)
    }

    private func applyFullCharge(_ on: Bool) {
        fullChargeEnabled = on
        defaults.set(on, forKey: Key.fullCharge)
    }

    /// 投递低电量通知并持久化冷却时间（触发与否已由策略裁决）。
    func sendLowBattery(level: Double) {
        content(title: "电池电量低", body: "电池电量剩余 \(Int(level))%，请连接充电器", identifier: "low-battery", category: "LOW_BATTERY")
        recordLowBatteryNotificationSent(at: Date())
    }

    /// 投递充满通知并持久化冷却时间。
    func sendFullCharge(level: Double) {
        content(title: "电池已充满", body: level >= 100 ? "电池已充满 100%，可以拔掉充电器" : "电池已充满，可以拔掉充电器", identifier: "full-charge", category: "FULL_CHARGE")
        recordFullChargeNotificationSent(at: Date())
    }

    private func content(title: String, body: String, identifier: String, category: String) {
        let notification = UNMutableNotificationContent()
        notification.title = title
        notification.body = body
        notification.sound = .default
        notification.categoryIdentifier = category

        let request = UNNotificationRequest(identifier: identifier, content: notification, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                notifLogger.error("Notification add failed: \(error.localizedDescription)")
            }
        }
    }

    /// 记录并持久化低电量冷却时间（间隔决策与投递两阶段，测试可通过该方法注入时间）。
    func recordLowBatteryNotificationSent(at date: Date) {
        defaults.set(date, forKey: Key.lastLowBattery)
    }

    /// 记录并持久化充满冷却时间。
    func recordFullChargeNotificationSent(at date: Date) {
        defaults.set(date, forKey: Key.lastFullCharge)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}