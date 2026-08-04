import Foundation
import UserNotifications
import os

private let notifLogger = Logger(subsystem: "com.batterybar", category: "Notification")

/// 通知管理器
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()

    // 时间戳字段：UNUserNotificationCenter.add 的 completion handler 在后台队列执行，
    // 用 NSLock 保护避免数据竞争
    private let lock = NSLock()
    private var _lastLowBatteryNotification: Date?
    private var _lastFullChargeNotification: Date?

    private var lastLowBatteryNotification: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _lastLowBatteryNotification }
        set { lock.lock(); _lastLowBatteryNotification = newValue; lock.unlock() }
    }
    private var lastFullChargeNotification: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _lastFullChargeNotification }
        set { lock.lock(); _lastFullChargeNotification = newValue; lock.unlock() }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
    }

    /// 请求通知权限
    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                notifLogger.info("Notification permission granted")
            } else if let error = error {
                notifLogger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    /// 检查并发送低电量通知
    /// - Parameter isCharging: 充电中不触发低电量通知（避免插电瞬间 level 仍 ≤20% 时的误报）
    func checkLowBattery(level: Double, isCharging: Bool) {
        guard !isCharging, level <= 20 else { return }

        // 避免频繁通知（至少间隔 30 分钟）
        if let last = lastLowBatteryNotification,
           Date().timeIntervalSince(last) < 1800 {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "电池电量低"
        content.body = "电池电量剩余 \(Int(level))%，请连接充电器"
        content.sound = .default
        content.categoryIdentifier = "LOW_BATTERY"

        let request = UNNotificationRequest(
            identifier: "low-battery",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error == nil else { return }
            self?.lastLowBatteryNotification = Date()
        }
    }

    /// 检查并发送满电通知
    func checkFullCharge(level: Double, wasCharging: Bool) {
        guard level >= 100, wasCharging else { return }

        // 避免频繁通知（至少间隔 60 分钟）
        if let last = lastFullChargeNotification,
           Date().timeIntervalSince(last) < 3600 {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "电池已充满"
        content.body = "电池已充满 100%，可以拔掉充电器"
        content.sound = .default
        content.categoryIdentifier = "FULL_CHARGE"

        let request = UNNotificationRequest(
            identifier: "full-charge",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error == nil else { return }
            self?.lastFullChargeNotification = Date()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
