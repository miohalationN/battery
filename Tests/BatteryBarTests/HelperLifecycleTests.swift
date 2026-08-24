import Foundation
import Testing
@testable import BatteryBar

/// HelperLifecycleController 反例：enable 可走安装/更新；disable 只停止采样、
/// 从不 uninstall；只有显式 remove 才卸载；安装错误进入 error 且可重试；
/// 启动检查绝不安装/卸载；迟到回写门控拒绝已关闭状态；生命周期标签完整。
/// 全部通过注入的 ops stub 完成，测试期间绝不触碰真实 Helper/launchd。
@Suite struct HelperLifecycleTests {

    private final class StubOps: HelperLifecycleOps, @unchecked Sendable {
        private let lock = NSLock()
        private var _installCount = 0
        private var _uninstallCount = 0
        private var _installResult = true
        private var _uninstallResult = true
        private var _installedState: InstalledHelperState = .notInstalled

        var installCount: Int {
            lock.lock(); defer { lock.unlock() }; return _installCount
        }
        var uninstallCount: Int {
            lock.lock(); defer { lock.unlock() }; return _uninstallCount
        }
        var installResult: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _installResult }
            set { lock.lock(); _installResult = newValue; lock.unlock() }
        }
        var uninstallResult: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _uninstallResult }
            set { lock.lock(); _uninstallResult = newValue; lock.unlock() }
        }
        var installedState: InstalledHelperState {
            get { lock.lock(); defer { lock.unlock() }; return _installedState }
            set { lock.lock(); _installedState = newValue; lock.unlock() }
        }

        func installOrUpdate() async -> Bool {
            incrementInstall()
            return installResult
        }
        func uninstall() async -> Bool {
            incrementUninstall()
            return uninstallResult
        }
        func installedHelperState() async -> InstalledHelperState {
            installedState
        }

        // NSLock.lock() 在 async 上下文不可用；计数变更收敛到同步辅助方法
        private func incrementInstall() {
            lock.lock(); defer { lock.unlock() }; _installCount += 1
        }
        private func incrementUninstall() {
            lock.lock(); defer { lock.unlock() }; _uninstallCount += 1
        }
    }

    @MainActor
    private func makeController(_ stub: StubOps) -> HelperLifecycleController {
        HelperLifecycleController(ops: stub)
    }

    @MainActor
    @Test("Helper 缺失或旧版本时 enable 可以走安装/更新")
    func enableInstallsWhenMissingOrOutdated() async {
        let stub = StubOps()
        let controller = makeController(stub)
        let ok = await controller.beginEnable()
        #expect(ok)
        #expect(stub.installCount == 1)
        #expect(controller.state == .enabled)
    }

    @MainActor
    @Test("disable 只停止采样，从不 uninstall")
    func disableNeverUninstalls() async {
        let stub = StubOps()
        let controller = makeController(stub)
        _ = await controller.beginEnable()
        controller.setDisabled()
        #expect(controller.state == .disabled)
        #expect(stub.uninstallCount == 0)
    }

    @MainActor
    @Test("只有显式 remove 才调用 uninstall")
    func onlyExplicitRemoveUninstalls() async {
        let stub = StubOps()
        let controller = makeController(stub)
        _ = await controller.refreshAtStartup(enabled: false)
        #expect(stub.uninstallCount == 0)
        _ = await controller.beginEnable()
        #expect(stub.uninstallCount == 0)

        let ok = await controller.remove()
        #expect(ok)
        #expect(stub.uninstallCount == 1)
        #expect(controller.state == .disabled)
    }

    @MainActor
    @Test("启动检查不安装、不卸载、不请求授权")
    func startupCheckNeverInstallsOrUninstalls() async {
        let stub = StubOps()
        stub.installedState = .needsUpdate
        let controller = makeController(stub)
        let state = await controller.refreshAtStartup(enabled: false)
        #expect(state == .needsUpdate)
        #expect(stub.installCount == 0)
        #expect(stub.uninstallCount == 0)
    }

    @MainActor
    @Test("安装错误进入 error 且可以重试")
    func installFailureEntersErrorAndRetryWorks() async {
        let stub = StubOps()
        stub.installResult = false
        let controller = makeController(stub)
        let first = await controller.beginEnable()
        #expect(!first)
        #expect(controller.state != .enabled)
        #expect(controller.lastErrorMessage?.isEmpty == false)

        // 重试：恢复可安装后成功
        stub.installResult = true
        let second = await controller.beginEnable()
        #expect(second)
        #expect(controller.state == .enabled)
        #expect(stub.installCount == 2)
    }

    @MainActor
    @Test("取消管理员授权恢复真实状态（返回失败且不进入 enabled）")
    func cancelAuthorizationRestoresRealState() async {
        let stub = StubOps()
        stub.installResult = false
        let controller = makeController(stub)
        #expect(await controller.beginEnable() == false)
        // 调用方据此不写持久化开启状态；此处状态机本身不假装已开启
        #expect(controller.state != .enabled)
        #expect(controller.state == .error("安装失败或已取消"))
    }

    @MainActor
    @Test("移除失败进入 error")
    func removeFailureEntersError() async {
        let stub = StubOps()
        stub.uninstallResult = false
        let controller = makeController(stub)
        let ok = await controller.remove()
        #expect(!ok)
        #expect(controller.state != .disabled)
    }

    @MainActor
    @Test("disable 后迟到回写门控拒绝")
    func lateResultGateRejectsAfterDisable() {
        // 关闭后（helperEnabled=false / 生命周期非 enabled）迟到结果不得写回
        #expect(!ComponentReadingGate.shouldApply(
            helperEnabled: false,
            lifecycleState: .disabled,
            isStarted: true
        ))
        #expect(!ComponentReadingGate.shouldApply(
            helperEnabled: true,
            lifecycleState: .disabled,
            isStarted: true
        ))
        #expect(!ComponentReadingGate.shouldApply(
            helperEnabled: true,
            lifecycleState: .error("x"),
            isStarted: true
        ))
        #expect(!ComponentReadingGate.shouldApply(
            helperEnabled: true,
            lifecycleState: .enabled,
            isStarted: false
        ))
        // 只有 enabled + 开关开 + 已启动才允许
        #expect(ComponentReadingGate.shouldApply(
            helperEnabled: true,
            lifecycleState: .enabled,
            isStarted: true
        ))
    }

    @MainActor
    @Test("生命周期 UI 标签映射互不相同且非空")
    func stateLabelsDistinctAndNonEmpty() {
        let states: [HelperLifecycleState] = [
            .disabled, .starting, .removing, .enabled, .needsUpdate, .error("x"),
        ]
        let labels = states.map(\.label)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == states.count)
    }

    /// 用 continuation 精确控制 await 返回顺序，覆盖顺序 Stub 无法发现的竞态。
    private final class ControlledOps: HelperLifecycleOps, @unchecked Sendable {
        private let lock = NSLock()
        private var startupContinuation: CheckedContinuation<InstalledHelperState, Never>?
        private var installContinuation: CheckedContinuation<Bool, Never>?
        private var uninstallContinuation: CheckedContinuation<Bool, Never>?
        private var _installCount = 0
        private var _uninstallCount = 0

        var installCount: Int { lock.lock(); defer { lock.unlock() }; return _installCount }
        var uninstallCount: Int { lock.lock(); defer { lock.unlock() }; return _uninstallCount }

        func installedHelperState() async -> InstalledHelperState {
            await withCheckedContinuation { continuation in
                lock.lock(); startupContinuation = continuation; lock.unlock()
            }
        }

        func installOrUpdate() async -> Bool {
            incrementInstall()
            return await withCheckedContinuation { continuation in
                lock.lock(); installContinuation = continuation; lock.unlock()
            }
        }

        func uninstall() async -> Bool {
            incrementUninstall()
            return await withCheckedContinuation { continuation in
                lock.lock(); uninstallContinuation = continuation; lock.unlock()
            }
        }

        private func incrementInstall() { lock.lock(); _installCount += 1; lock.unlock() }
        private func incrementUninstall() { lock.lock(); _uninstallCount += 1; lock.unlock() }
        private func hasStartup() -> Bool { lock.lock(); defer { lock.unlock() }; return startupContinuation != nil }
        private func hasInstall() -> Bool { lock.lock(); defer { lock.unlock() }; return installContinuation != nil }
        private func hasUninstall() -> Bool { lock.lock(); defer { lock.unlock() }; return uninstallContinuation != nil }

        func waitForStartup() async { while !hasStartup() { await Task.yield() } }
        func waitForInstall() async { while !hasInstall() { await Task.yield() } }
        func waitForUninstall() async { while !hasUninstall() { await Task.yield() } }

        func finishStartup(_ result: InstalledHelperState) {
            lock.lock(); let continuation = startupContinuation; startupContinuation = nil; lock.unlock()
            continuation?.resume(returning: result)
        }

        func finishInstall(_ result: Bool) {
            lock.lock(); let continuation = installContinuation; installContinuation = nil; lock.unlock()
            continuation?.resume(returning: result)
        }

        func finishUninstall(_ result: Bool) {
            lock.lock(); let continuation = uninstallContinuation; uninstallContinuation = nil; lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    @MainActor
    @Test("迟到的启动检查不得覆盖更新的用户开启")
    func staleStartupCheckCannotOverrideNewerEnable() async {
        let stub = ControlledOps()
        let controller = HelperLifecycleController(ops: stub)
        let startup = Task { @MainActor in await controller.refreshAtStartup(enabled: false) }
        await stub.waitForStartup()

        let enable = Task { @MainActor in await controller.beginEnable() }
        await stub.waitForInstall()
        stub.finishInstall(true)
        #expect(await enable.value)
        #expect(controller.state == .enabled)

        stub.finishStartup(.current)
        _ = await startup.value
        #expect(controller.state == .enabled)
        #expect(controller.installedState == .current)
    }

    @MainActor
    @Test("关闭会使迟到的安装结果失效但保留已安装磁盘事实")
    func disableInvalidatesLateEnableResult() async {
        let stub = ControlledOps()
        let controller = HelperLifecycleController(ops: stub)
        let enable = Task { @MainActor in await controller.beginEnable() }
        await stub.waitForInstall()
        controller.setDisabled()
        stub.finishInstall(true)

        #expect(await enable.value == false)
        #expect(controller.state == .disabled)
        #expect(controller.installedState == .current)
    }

    @MainActor
    @Test("移除期间拒绝并发安装")
    func removeAndEnableNeverOverlap() async {
        let stub = ControlledOps()
        let controller = HelperLifecycleController(ops: stub)
        let remove = Task { @MainActor in await controller.remove() }
        await stub.waitForUninstall()
        #expect(controller.state == .removing)

        #expect(await controller.beginEnable() == false)
        #expect(stub.installCount == 0)
        stub.finishUninstall(true)
        #expect(await remove.value)
        #expect(controller.state == .disabled)
        #expect(controller.installedState == .notInstalled)
        #expect(stub.uninstallCount == 1)
    }

    @MainActor
    @Test("重复移除只执行一次卸载")
    func duplicateRemoveIsCoalescedByBusyGate() async {
        let stub = ControlledOps()
        let controller = HelperLifecycleController(ops: stub)
        let first = Task { @MainActor in await controller.remove() }
        await stub.waitForUninstall()
        #expect(await controller.remove() == false)
        #expect(stub.uninstallCount == 1)
        stub.finishUninstall(true)
        #expect(await first.value)
    }

    @MainActor
    @Test("磁盘缺失不能把残留开启值冒充 enabled")
    func missingHelperRejectsPersistedEnabledState() async {
        let stub = StubOps()
        stub.installedState = .notInstalled
        let controller = makeController(stub)
        #expect(await controller.refreshAtStartup(enabled: true) == .disabled)
        #expect(controller.installedState == .notInstalled)
        #expect(controller.lastErrorMessage?.isEmpty == false)
    }
}
