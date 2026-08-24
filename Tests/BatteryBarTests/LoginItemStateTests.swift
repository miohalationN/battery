import Foundation
import Testing
@testable import BatteryBar

/// 开机自启动共享状态反例：右键菜单与设置 Toggle 消费同一 LoginItemState，
/// register/unregister 失败必须恢复真实状态并返回可理解错误；
/// requiresApproval 不得假装已开启。
@Suite struct LoginItemStateTests {

    private final class StubController: LoginItemControlling, @unchecked Sendable {
        var registerError: Error?
        var unregisterError: Error?
        private let lock = NSLock()
        private var lockStatus: LoginItemStatus = .notRegistered

        func currentStatus() -> LoginItemStatus {
            lock.lock(); defer { lock.unlock() }
            return lockStatus
        }
        func register() throws {
            if let error = registerError { throw error }
            setLocked(.enabled)
        }
        func unregister() throws {
            if let error = unregisterError { throw error }
            setLocked(.notRegistered)
        }
        func openApprovalSettings() {}

        private func setLocked(_ value: LoginItemStatus) {
            lock.lock(); defer { lock.unlock() }
            lockStatus = value
        }

        func setStatus(_ value: LoginItemStatus) {
            setLocked(value)
        }
    }

    @MainActor
    private func makeModel(
        status: LoginItemStatus = .notRegistered,
        registerError: Error? = nil,
        unregisterError: Error? = nil
    ) -> (LoginItemState, StubController) {
        let controller = StubController()
        controller.setStatus(status)
        controller.registerError = registerError
        controller.unregisterError = unregisterError
        return (LoginItemState(controller: controller), controller)
    }

    @MainActor
    @Test func enableSucceedsAndReflectsRealState() {
        let (model, _) = makeModel()
        #expect(!model.isOn)
        let error = model.setEnabled(true)
        #expect(error == nil)
        #expect(model.isOn)
        #expect(model.status == .enabled)
    }

    @MainActor
    @Test func disableSucceedsAndReflectsRealState() {
        let (model, _) = makeModel(status: .enabled)
        #expect(model.isOn)
        let error = model.setEnabled(false)
        #expect(error == nil)
        #expect(model.status == .notRegistered)
        #expect(!model.isOn)
    }

    /// requiresApproval：不得假装已开启，且给出明确指引状态
    @MainActor
    @Test func requiresApprovalDoesNotPretendEnabled() {
        let (model, _) = makeModel(status: .requiresApproval)
        #expect(!model.isOn)
        #expect(model.needsApproval)
        #expect(model.statusSubtitle.contains("系统设置"))
    }

    /// 注册失败：开关动作返回错误文案，状态恢复为真实系统状态
    @MainActor
    @Test func registerFailureRestoresRealStatusAndReports() {
        struct Boom: Error {}
        let (model, _) = makeModel(status: .notRegistered, registerError: Boom())
        let message = model.setEnabled(true)
        #expect(message?.contains("开启") == true)
        #expect(message?.contains("失败") == true)
        #expect(model.status == .notRegistered)
        #expect(!model.isOn)
    }

    /// 注销失败：同样返回错误并保持真实状态
    @MainActor
    @Test func unregisterFailureKeepsEnabledState() {
        struct Boom: Error {}
        let (model, _) = makeModel(status: .enabled, unregisterError: Boom())
        let message = model.setEnabled(false)
        #expect(message?.contains("关闭") == true)
        #expect(model.status == .enabled)
        #expect(model.isOn)
    }

    /// refresh() 始终读取系统真实状态（外部改动可被感知）
    @MainActor
    @Test func refreshReadsUnderlyingSystemState() {
        let (model, controller) = makeModel()
        controller.setStatus(.requiresApproval)
        model.refresh()
        #expect(model.needsApproval)
    }
}
