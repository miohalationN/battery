import Foundation

/// 通知触发策略（纯逻辑，无 UserNotifications / 系统权限依赖）。
///
/// 低电量与充满提醒的全部触发门槛、冷却窗口在这里裁决；冷却时间戳由调用方
/// 持久化（UserDefaults），因此 BA 重启后依然遵守冷却窗口。
///
/// 低电量禁止情形（满足任一即不触发）：
/// - 外接电源明确接上（externalConnected == true）
/// - 外接电源状态未知（externalConnected == nil）
/// - 当前正在充电
/// - 低电量开关关闭 / 通知权限无效
///
/// 充满触发前提：外接电源明确接上、前一状态明确正在充电、当前已停止充电、
/// 当前电量达到充满门槛、开关开启、权限有效、冷却结束。
enum NotificationPolicy {
    /// 低电量提醒电量阈值
    static let lowBatteryThreshold: Double = 20
    /// 低电量提醒冷却窗口（30 分钟）
    static let lowBatteryCooldown: TimeInterval = 30 * 60
    /// 充满提醒冷却窗口（60 分钟）
    static let fullChargeCooldown: TimeInterval = 60 * 60
    /// 充满门槛
    static let fullChargeLevel: Double = 100

    /// 低电量是否应当触发。
    /// - Parameters:
    ///   - externalConnected: 是否接外接电源；nil 表示来源未知（禁止触发）
    ///   - lastNotificationAt: 上次低电量通知时间（nil = 从未通知，视为冷却已结束）
    static func shouldSendLowBattery(
        level: Double,
        externalConnected: Bool?,
        isCharging: Bool,
        lowBatteryEnabled: Bool,
        permissionValid: Bool,
        lastNotificationAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard lowBatteryEnabled, permissionValid else { return false }
        guard externalConnected == false else { return false }
        guard !isCharging else { return false }
        guard level <= lowBatteryThreshold else { return false }
        return cooldownElapsed(last: lastNotificationAt, cooldown: lowBatteryCooldown, now: now)
    }

    /// 充满是否应当触发。
    static func shouldSendFullCharge(
        level: Double,
        externalConnected: Bool?,
        wasCharging: Bool,
        isCharging: Bool,
        fullChargeEnabled: Bool,
        permissionValid: Bool,
        lastNotificationAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard fullChargeEnabled, permissionValid else { return false }
        guard externalConnected == true else { return false }
        guard wasCharging else { return false }
        guard !isCharging else { return false }
        guard level >= fullChargeLevel else { return false }
        return cooldownElapsed(last: lastNotificationAt, cooldown: fullChargeCooldown, now: now)
    }

    /// 冷却窗口是否已结束。
    static func cooldownElapsed(last: Date?, cooldown: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }
}