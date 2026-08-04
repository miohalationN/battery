import Foundation
import AppKit

/// 监听系统休眠/唤醒事件（通过 NSWorkspace 通知）
final class SleepWatcher: @unchecked Sendable {
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isStarted = false

    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSleep?()
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onWake?()
        }
    }

    func stop() {
        if let obs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            sleepObserver = nil
        }
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        isStarted = false
    }

    deinit {
        stop()
    }
}
