import Foundation
import Testing
@testable import BatteryBar

/// 通知触发策略纯逻辑反例：不依赖 UserNotifications / 系统权限，
/// 冷却窗口使用外部注入的时间戳（由调用方持久化，重启后依然生效）。
@Suite struct NotificationPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 低电量

    @Test("明确离电且低电量可以触发")
    func lowBatteryFiresWhenDisconnected() {
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("接电未充电禁止低电量提醒")
    func lowBatteryBlockedWhenPluggedNotCharging() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: true,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("正在充电禁止低电量提醒")
    func lowBatteryBlockedWhileCharging() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: true,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("电源来源未知禁止低电量提醒")
    func lowBatteryBlockedWhenSourceUnknown() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: nil,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("电量高于阈值禁止低电量提醒")
    func lowBatteryBlockedAboveThreshold() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 21,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("用户关闭低电量开关后策略拒绝触发")
    func lowBatteryBlockedWhenToggleOff() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: false,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("权限无效禁止低电量提醒")
    func lowBatteryBlockedWhenPermissionInvalid() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: false,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("冷却窗口未结束禁止低电量提醒")
    func lowBatteryBlockedByCooldown() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-100),
            now: now
        ))
    }

    @Test("冷却窗口结束后允许再次提醒")
    func lowBatteryAllowedAfterCooldown() {
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-NotificationPolicy.lowBatteryCooldown - 1),
            now: now
        ))
    }

    // MARK: - 充满

    @Test("充满提醒要求外接电源为 true")
    func fullChargeRequiresExternalConnected() {
        let base = { (external: Bool?) in
            NotificationPolicy.shouldSendFullCharge(
                level: 100,
                externalConnected: external,
                wasCharging: true,
                isCharging: false,
                fullChargeEnabled: true,
                permissionValid: true,
                lastNotificationAt: nil,
                now: now
            )
        }
        #expect(base(nil) == false)
        #expect(base(false) == false)
        #expect(base(true) == true)
    }

    @Test("充满提醒要求前一状态明确正在充电")
    func fullChargeRequiresPreviousCharging() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: false,
            isCharging: false,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒要求当前状态停止充电")
    func fullChargeRequiresNotChargingNow() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: true,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒要求达到充满门槛")
    func fullChargeRequiresFullLevel() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 99,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒全条件满足可以触发")
    func fullChargeFiresWhenAllConditionsMet() {
        #expect(NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒用户关闭后策略拒绝触发")
    func fullChargeBlockedWhenToggleOff() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            fullChargeEnabled: false,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒冷却窗口未结束禁止触发")
    func fullChargeBlockedByCooldown() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-60),
            now: now
        ))
    }
}