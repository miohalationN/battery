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
        private var _statusAfterGrant: NotificationAuthorization? = .authorized

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
        var statusAfterGrant: NotificationAuthorization? {
            get { lock.lock(); defer { lock.unlock() }; return _statusAfterGrant }
            set { lock.lock(); _statusAfterGrant = newValue; lock.unlock() }
        }

        func currentAuthorization() async -> NotificationAuthorization {
            status
        }

        func requestAuthorization() async -> Bool {
            incrementRequests()
            let granted = grantedResult
            if granted, let next = statusAfterGrant { status = next }
            return granted
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
        granted: Bool = true,
        reset: Bool = true
    ) -> (NotificationManager, StubAuthorizer) {
        let defaults = UserDefaults(suiteName: suite)!
        if reset {
            // 只有创建全新持久化域时才清空；模拟 BA 重启重建管理器时
            // 必须保留上一次写入的用户选择与冷却时间戳
            defaults.removePersistentDomain(forName: suite)
        }
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

        // 模拟 BA 重启：用同一持久化域重建管理器（不重置域，保留冷却时间戳）
        let (rebuilt, _) = makeManager(suite: suite, status: .authorized, reset: false)
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
        let (rebuilt, _) = makeManager(suite: suite, status: .authorized, reset: false)
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

    @MainActor
    @Test("缓存 denied 时主动开启会先读取系统设置中的新授权")
    func activeEnableRefreshesStaleDeniedState() async {
        let (manager, authorizer) = makeManager(status: .denied)
        await manager.start()
        authorizer.status = .authorized

        await manager.setLowBatteryEnabled(true)
        #expect(manager.authorizationState == .authorized)
        #expect(manager.lowBatteryEnabled)
        #expect(authorizer.requestCount == 0)
    }

    @MainActor
    @Test("主动开启读到 denied 时统一关闭另一个残留开启项")
    func activeEnableDeniedClosesBothPersistedToggles() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let (manager, authorizer) = makeManager(suite: suite, status: .authorized)
        await manager.start()
        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)

        authorizer.status = .denied
        await manager.setFullChargeEnabled(true)

        #expect(manager.authorizationState == .denied)
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.fullChargeEnabled)
        let defaults = UserDefaults(suiteName: suite)!
        #expect(defaults.bool(forKey: "BatteryBarNotifyLowBattery") == false)
        #expect(defaults.bool(forKey: "BatteryBarNotifyFullCharge") == false)
        #expect(authorizer.requestCount == 0)
    }

    @MainActor
    @Test("App 激活使用的被动刷新只读权限且可观察外部授权")
    func passiveRefreshObservesExternalGrantWithoutRequest() async {
        let (manager, authorizer) = makeManager(status: .denied)
        await manager.start()
        authorizer.status = .authorized

        await manager.refreshAuthorization()
        #expect(manager.authorizationState == .authorized)
        #expect(authorizer.requestCount == 0)
    }

    private final class OutOfOrderRefreshAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var currentCallCount = 0
        private var secondContinuation: CheckedContinuation<NotificationAuthorization, Never>?
        private var thirdContinuation: CheckedContinuation<NotificationAuthorization, Never>?

        func currentAuthorization() async -> NotificationAuthorization {
            switch nextCall() {
            case 1:
                return .authorized
            case 2:
                return await withCheckedContinuation { continuation in
                    lock.lock(); secondContinuation = continuation; lock.unlock()
                }
            default:
                return await withCheckedContinuation { continuation in
                    lock.lock(); thirdContinuation = continuation; lock.unlock()
                }
            }
        }

        func requestAuthorization() async -> Bool { false }

        private func nextCall() -> Int {
            lock.lock(); defer { lock.unlock() }
            currentCallCount += 1
            return currentCallCount
        }
        private func hasSecond() -> Bool {
            lock.lock(); defer { lock.unlock() }; return secondContinuation != nil
        }
        private func hasThird() -> Bool {
            lock.lock(); defer { lock.unlock() }; return thirdContinuation != nil
        }
        func waitForSecond() async { while !hasSecond() { await Task.yield() } }
        func waitForThird() async { while !hasThird() { await Task.yield() } }
        func finishSecond(_ state: NotificationAuthorization) {
            lock.lock(); let continuation = secondContinuation; secondContinuation = nil; lock.unlock()
            continuation?.resume(returning: state)
        }
        func finishThird(_ state: NotificationAuthorization) {
            lock.lock(); let continuation = thirdContinuation; thirdContinuation = nil; lock.unlock()
            continuation?.resume(returning: state)
        }
    }

    @MainActor
    @Test("迟到的旧被动授权查询不得覆盖较新的结果")
    func stalePassiveRefreshCannotOverrideNewerResult() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let authorizer = OutOfOrderRefreshAuthorizer()
        let manager = NotificationManager(authorizer: authorizer, defaults: defaults)
        await manager.start()
        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)

        let older = Task { @MainActor in await manager.refreshAuthorization() }
        await authorizer.waitForSecond()
        let newer = Task { @MainActor in await manager.refreshAuthorization() }
        await authorizer.waitForThird()

        authorizer.finishThird(.authorized)
        await newer.value
        authorizer.finishSecond(.denied)
        await older.value

        #expect(manager.authorizationState == .authorized)
        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)
    }

    @MainActor
    @Test("request 返回 true 但真实权限仍无效时开关保持关闭")
    func grantedBooleanWithoutValidStateKeepsToggleOff() async {
        let (manager, authorizer) = makeManager(status: .notDetermined, granted: true)
        authorizer.statusAfterGrant = .notDetermined
        await manager.start()

        await manager.setLowBatteryEnabled(true)
        #expect(!manager.lowBatteryEnabled)
        #expect(!manager.permissionValid)
        #expect(authorizer.requestCount == 1)
        #expect(manager.lastErrorMessage?.isEmpty == false)
    }

    private final class DelayedStartAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var firstContinuation: CheckedContinuation<NotificationAuthorization, Never>?
        private var currentCallCount = 0
        private var _state: NotificationAuthorization = .notDetermined
        private var _requestCount = 0

        var state: NotificationAuthorization {
            get { lock.lock(); defer { lock.unlock() }; return _state }
            set { lock.lock(); _state = newValue; lock.unlock() }
        }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

        func currentAuthorization() async -> NotificationAuthorization {
            let call = nextCurrentCall()
            if call == 1 {
                return await withCheckedContinuation { continuation in
                    lock.lock(); firstContinuation = continuation; lock.unlock()
                }
            }
            return state
        }

        func requestAuthorization() async -> Bool {
            incrementRequests()
            return false
        }

        private func nextCurrentCall() -> Int {
            lock.lock(); defer { lock.unlock() }
            currentCallCount += 1
            return currentCallCount
        }
        private func incrementRequests() { lock.lock(); _requestCount += 1; lock.unlock() }
        private func hasFirstContinuation() -> Bool {
            lock.lock(); defer { lock.unlock() }; return firstContinuation != nil
        }
        func waitForFirstQuery() async {
            while !hasFirstContinuation() { await Task.yield() }
        }
        func finishFirstQuery(_ state: NotificationAuthorization) {
            lock.lock(); let continuation = firstContinuation; firstContinuation = nil; lock.unlock()
            continuation?.resume(returning: state)
        }
    }

    @MainActor
    @Test("迟到的首次初始化不得覆盖更新的用户选择")
    func staleStartCannotOverrideUserToggle() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let authorizer = DelayedStartAuthorizer()
        let manager = NotificationManager(authorizer: authorizer, defaults: defaults)

        let startup = Task { @MainActor in await manager.start() }
        await authorizer.waitForFirstQuery()
        authorizer.state = .authorized
        await manager.setLowBatteryEnabled(true)
        #expect(manager.lowBatteryEnabled)

        authorizer.finishFirstQuery(.notDetermined)
        await startup.value
        #expect(manager.lowBatteryEnabled)
        #expect(defaults.string(forKey: "BatteryBarNotificationInitialized") == "1")
        #expect(authorizer.requestCount == 0)
    }

    @MainActor
    @Test("首次初始化被较新被动刷新淘汰后会用最新状态完成初始化")
    func staleStartRetriesAfterNewerPassiveRefresh() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let authorizer = DelayedStartAuthorizer()
        authorizer.state = .authorized
        let manager = NotificationManager(authorizer: authorizer, defaults: defaults)

        let startup = Task { @MainActor in await manager.start() }
        await authorizer.waitForFirstQuery()
        await manager.refreshAuthorization()
        authorizer.finishFirstQuery(.denied)
        await startup.value

        #expect(manager.authorizationState == .authorized)
        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)
        #expect(defaults.string(forKey: "BatteryBarNotificationInitialized") == "1")
        #expect(authorizer.requestCount == 0)
    }

    private final class DelayedRequestAuthorizer: NotificationAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var _state: NotificationAuthorization = .notDetermined
        private var _requestCount = 0
        private var requestContinuation: CheckedContinuation<Bool, Never>?

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

        func currentAuthorization() async -> NotificationAuthorization {
            currentState()
        }

        func requestAuthorization() async -> Bool {
            incrementRequests()
            return await withCheckedContinuation { continuation in
                lock.lock(); requestContinuation = continuation; lock.unlock()
            }
        }

        private func incrementRequests() { lock.lock(); _requestCount += 1; lock.unlock() }
        private func currentState() -> NotificationAuthorization {
            lock.lock(); defer { lock.unlock() }; return _state
        }
        private func hasContinuation() -> Bool {
            lock.lock(); defer { lock.unlock() }; return requestContinuation != nil
        }
        func waitForRequest() async { while !hasContinuation() { await Task.yield() } }
        func grant() {
            lock.lock()
            _state = .authorized
            let continuation = requestContinuation
            requestContinuation = nil
            lock.unlock()
            continuation?.resume(returning: true)
        }
    }

    @MainActor
    @Test("同时开启两个提醒只请求一次系统权限")
    func concurrentTogglesSharePermissionRequest() async {
        let suite = "bb-notif-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let authorizer = DelayedRequestAuthorizer()
        let manager = NotificationManager(authorizer: authorizer, defaults: defaults)
        await manager.start()

        let low = Task { @MainActor in await manager.setLowBatteryEnabled(true) }
        let full = Task { @MainActor in await manager.setFullChargeEnabled(true) }
        await authorizer.waitForRequest()
        #expect(authorizer.requestCount == 1)
        authorizer.grant()
        await low.value
        await full.value

        #expect(manager.lowBatteryEnabled)
        #expect(manager.fullChargeEnabled)
        #expect(authorizer.requestCount == 1)
    }
}
