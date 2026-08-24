import Foundation
import Testing
@testable import BatteryBar

/// NotificationManager 反例：创建/启动/刷新都不请求权限；
/// 只允许用户主动开启且 notDetermined 时请求；denied 恢复真实关闭；
/// 冷却时间持久化在 UserDefaults，重建管理器后依然生效；
/// 版本化 initialized 标记写入后不得覆盖用户选择。
@Suite struct NotificationManagerTests {

    private final class StubAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: NotificationAuthorization = .notDetermined
        private var _requests = 0
        private var _granted = false

        var status: NotificationAuthorization {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); _status = newValue; lock.unlock() }
        }
        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }; return _requests
        }
        var grantedResult: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _granted }
            set { lock.lock(); _granted = newValue; lock.unlock() }
        }

        func currentAuthorization() async -> NotificationAuthorization {
            status
        }

        func requestAuthorization() async -> Bool {
            incrementRequests()
            return grantedResult
        }

        // NSLock.lock() 在 async 上下文不可用；计数变更收敛到同步辅助方法
        private func incrementRequests() {
            lock.lock(); defer { lock.unlock() }; _requests += 1
        }
    }

    @MainActor
    private func makeManager(
        suite: String = "bb-notif-test-\(UUID().uuidString)",
        status: NotificationAuthorization = .notDetermined,
        granted: Bool = true
    ) -> (NotificationManager, StubAuthorizer) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let authorizer = StubAuthorizer()
        authorizer.status = status
        authorizer.grantedResult = granted
        return (NotificationManager(authorizer: authorizer, defaults: defaults), authorizer)
    }

    @MainActor
    @Test("创建 NotificationManager 不请求权限")
    func creatingManagerDoesNotRequestPermission() {
        let (manager, authorizer) = makeManager()
        #expect(authorizer.requestCount == 0)
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)
        #expect(!manager.permissionValid)
    }

    @MainActor
    @Test("notDetermined 首次初始化两个开关关闭且不请求权限")
    func notDeterminedFirstInitDefaultsBothOff() async {
        let (manager, authorizer) = makeManager(status: .notDetermined)
        await manager.start()
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)
        #expect(manager.authorizationState == .notDetermined)
        #expect(authorizer.requestCount == 0)
    }

    @MainActor
    @Test("authorized 旧用户初始化兼容：两开关默认开启")
    func authorizedLegacyUserDefaultsBothOn() async {
        let (manager, authorizer) = makeManager(status: .authorized)
        await manager.start()
        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)
        #expect(manager.permissionValid)
        #expect(authorizer.requestCount == 0)
    }

    @MainActor
    @Test("用户可只开启其中一种提醒")
    func userCanEnableOnlyOneKind() async {
        let (manager, authorizer) = makeManager(status: .notDetermined, granted: true)
        await manager.start()
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)

        await manager.setLowBatteryEnabled(true)
        #expect(manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)
        #expect(authorizer.requestCount == 1)
    }

    @MainActor
    @Test("请求被拒后开关保持关闭")
    func requestDeniedKeepsToggleOff() async {
        let (manager, authorizer) = makeManager(status: .notDetermined, granted: false)
        await manager.start()
        await manager.setLowBatteryEnabled(true)
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.permissionValid)
        #expect(authorizer.requestCount == 1)
        #expect(manager.lastErrorMessage?.isEmpty == false)
    }

    @MainActor
    @Test("权限已拒绝时开启开关恢复真实关闭且不再请求")
    func permissionDeniedRecoversToggleOff() async {
        let (manager, authorizer) = makeManager(status: .denied)
        await manager.start()
        #expect(!manager.lowBatteryEnabled)
        await manager.setLowBatteryEnabled(true)
        #expect(!manager.lowBatteryEnabled)
        #expect(authorizer.requestCount == 0)
        #expect(manager.lastErrorMessage?.isEmpty == false)
    }

    @MainActor
    @Test("系统设置中权限被拒后刷新恢复真实关闭并持久化")
    func deniedRefreshForcesPersistedToggleOff() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let (manager, authorizer) = makeManager(suite: suite, status: .authorized)
        await manager.start()
        #expect(manager.lowBatteryEnabled)

        authorizer.status = .denied
        await manager.refreshAuthorization()
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)

        let defaults = UserDefaults(suiteName: suite)!
        #expect(defaults.bool(forKey: "BatteryBarNotifyLowBattery") == false)
        #expect(defaults.bool(forKey: "BatteryBarNotifyFullCharge") == false)
    }

    @MainActor
    @Test("模型重建后通知冷却仍有效（时间戳持久化）")
    func cooldownPersistsAcrossRebuild() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (manager, _) = makeManager(suite: suite, status: .authorized)
        await manager.start()
        manager.recordLowBatteryNotificationSent(at: now)

        // 模拟 BA 重启：用同一持久化域重建管理器
        let (rebuilt, _) = makeManager(suite: suite, status: .authorized)
        await rebuilt.start()
        #expect(rebuilt.lastLowBatteryNotificationAt != nil)
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: rebuilt.lowBatteryEnabled,
            permissionValid: rebuilt.permissionValid,
            lastNotificationAt: rebuilt.lastLowBatteryNotificationAt,
            now: now.addingTimeInterval(600)
        ) == false)
        // 冷却窗口结束后可以再次触发
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: rebuilt.lowBatteryEnabled,
            permissionValid: rebuilt.permissionValid,
            lastNotificationAt: rebuilt.lastLowBatteryNotificationAt,
            now: now.addingTimeInterval(NotificationPolicy.lowBatteryCooldown + 1)
        ) == true)
    }

    @MainActor
    @Test("initialized 标记写入后不覆盖用户选择")
    func initializedMarkerPreservesUserChoicesAcrossRebuild() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let (manager, _) = makeManager(suite: suite, status: .authorized)
        await manager.start()
        await manager.setFullChargeEnabled(false)

        // 重启后系统授权仍为 authorized，但用户已显式关闭充满提醒：
        // 不得按旧行为重新推导为开启
        let (rebuilt, _) = makeManager(suite: suite, status: .authorized)
        await rebuilt.start()
        #expect(!rebuilt.fullChargeEnabled)
        #expect(rebuilt.lowBatteryEnabled)
    }

    @MainActor
    @Test("开关开启且权限有效时策略允许低电量触发")
    func enabledToggleAndValidPermissionAllowLowBatteryTrigger() async {
        let (manager, _) = makeManager(status: .authorized)
        await manager.start()
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: manager.lowBatteryEnabled,
            permissionValid: manager.permissionValid,
            lastNotificationAt: nil
        ))
    }

    @MainActor
    @Test("用户关闭提醒后策略拒绝触发")
    func userDisabledTogglesPreventTrigger() async {
        let (manager, _) = makeManager(status: .authorized)
        await manager.start()
        await manager.setLowBatteryEnabled(false)
        await manager.setFullChargeEnabled(false)
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: manager.lowBatteryEnabled,
            permissionValid: manager.permissionValid,
            lastNotificationAt: nil
        ))
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            fullChargeEnabled: manager.fullChargeEnabled,
            permissionValid: manager.permissionValid,
            lastNotificationAt: nil
        ))
    }
}