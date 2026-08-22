import Foundation
import Security

/// XPC 协议
@objc protocol HelperProtocol {
    // 读取 CPU/GPU/DRAM 功率（返回最近一次 powermetrics 采样缓存）
    // reply 标注 @Sendable：XPC 回调由 libxpc 在任意线程调用
    func getComponentPower(withReply reply: @escaping @Sendable (NSDictionary) -> Void)
    // 返回 helper 版本号（用于检测是否需要更新）
    func getVersion(withReply reply: @escaping (String) -> Void)
}

/// Privileged Helper — 以 root 权限常驻运行，通过 XPC 通信。
///
/// v4.1：继承 4.0 流式采样架构，并直接拒绝未通过签名校验的 XPC 连接。
/// v4.0 重大变更：
/// - powermetrics 从「每次调用 spawn 子进程」改为懒启动常驻流式进程
///   （`-i 10000` 每 10s 输出一轮采样，逐行解析缓存最新值）。
///   XPC 调用直接回缓存，不再 spawn/等待，消除 v3 每 10s 冷启动的开销。
/// - 进程生命周期：首个请求启动；60s 无请求自动退出（app 关闭/关闭开关后零开销）；
///   活跃期内意外退出自动重启。
/// - XPC 调用方校验：仅接受签名有效且 bundle id 为 com.batterybar.app 的进程。
///
/// 并发模型：`@unchecked Sendable` 的依据是队列收敛——所有可变状态
/// （metricsProcess / latest* / lastRequestAt / pendingBuffer）只在
/// powerQueue（串行）上访问；isCallerAllowed 只用局部变量，无共享状态。
class HelperTool: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener: NSXPCListener

    /// powermetrics 进程状态只在 powerQueue（串行）上访问
    private let powerQueue = DispatchQueue(label: "com.batterybar.helper.powermetrics")
    private var metricsProcess: Process?
    private var pendingBuffer = ""
    private var latestCPU: Double = 0
    private var latestGPU: Double = 0
    private var latestDRAM: Double = 0
    private var lastRequestAt = Date.distantPast
    private let idleTimeout: TimeInterval = 60
    private var idleTimer: DispatchSourceTimer?
    // 启动失败退避：参数无效/二进制异常时避免 1s 重启风暴
    private var processStartedAt = Date.distantPast
    private var failedStarts = 0
    private var cooldownUntil = Date.distantPast

    override init() {
        self.listener = NSXPCListener(machServiceName: "com.batterybar.helper")
        super.init()
        self.listener.delegate = self
        powerQueue.async { [self] in
            scheduleIdleCheckLocked()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isCallerAllowed(connection) else {
            // 直接拒绝未授权连接，不为其分配已恢复但无导出对象的空连接。
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// 调用方校验：pid 反查 SecCode，要求签名有效（未被篡改）且 bundle id 匹配。
    ///
    /// 局限性（有意接受）：ad-hoc 签名无 TeamID，无法做同一开发者强校验，
    /// 这里校验的是「代码完整 + bundle id 正确」，防的是随意进程白嫖 root helper；
    /// 发布版换 Developer ID 后应改为硬编码 designated requirement。
    private func isCallerAllowed(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        // 有效签名：代码与其自身 designated requirement（ad-hoc 即 cdhash）一致，未被篡改
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return false
        }
        guard let identifier = codeIdentifier(code) else { return false }
        return identifier == "com.batterybar.app"
    }

    private func codeIdentifier(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }
}

extension HelperTool: HelperProtocol {
    func getComponentPower(withReply reply: @escaping @Sendable (NSDictionary) -> Void) {
        powerQueue.async { [self] in
            lastRequestAt = Date()
            // 懒启动：进程不在跑（未启动/已退出/空闲退出）则启动
            if metricsProcess == nil {
                startPowermetricsLocked()
            }
            // 流式模式下直接返回最近采样（刚启动时可能还是 0，下一轮请求即有值）
            reply(["cpu": latestCPU, "gpu": latestGPU, "dram": latestDRAM])
        }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply("4.1")
    }

    // MARK: - powermetrics 流式进程管理（以下方法均在 powerQueue 上执行）

    /// 采样器按系统版本选择：macOS 27 起移除 dram 采样器
    /// （带无效采样器启动会整体失败，导致分项功耗全 0——2026-08-22 修复的隐性回归）
    private func powermetricsArguments() -> [String] {
        var samplers = ["cpu_power", "gpu_power"]
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            samplers.append("dram")
        }
        return ["--samplers", samplers.joined(separator: ","), "-i", "10000"]
    }

    private func startPowermetricsLocked() {
        // 连续快速失败后的冷却期内不再尝试
        guard Date() >= cooldownUntil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = powermetricsArguments()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // 意外退出：仍在活跃期则自动重启（launchd 不管理子进程）；
        // 存活 <10s 视为启动失败，连续 3 次进入 60s 冷却（防重启风暴）
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            self.powerQueue.async {
                self.metricsProcess = nil
                let uptime = Date().timeIntervalSince(self.processStartedAt)
                if uptime < 10 {
                    self.failedStarts += 1
                    if self.failedStarts >= 3 {
                        self.cooldownUntil = Date().addingTimeInterval(60)
                        self.failedStarts = 0
                        return
                    }
                } else {
                    self.failedStarts = 0
                }
                if Date().timeIntervalSince(self.lastRequestAt) < self.idleTimeout,
                   Date() >= self.cooldownUntil {
                    self.powerQueue.asyncAfter(deadline: .now() + 1.0) {
                        if self.metricsProcess == nil,
                           Date().timeIntervalSince(self.lastRequestAt) < self.idleTimeout,
                           Date() >= self.cooldownUntil {
                            self.startPowermetricsLocked()
                        }
                    }
                }
            }
        }

        // 逐段读取 stdout，按行解析（readabilityHandler 在系统 IO 线程，
        // 统一调度回 powerQueue 保证状态串行）
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.powerQueue.async {
                self.consumeOutputLocked(chunk)
            }
        }

        do {
            try process.run()
            processStartedAt = Date()
            metricsProcess = process
        } catch {
            // 启动失败：保持 metricsProcess 为 nil，计入退避
            failedStarts += 1
            if failedStarts >= 3 {
                cooldownUntil = Date().addingTimeInterval(60)
                failedStarts = 0
            }
        }
    }

    private func consumeOutputLocked(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        pendingBuffer += text
        var lines = pendingBuffer.split(separator: "\n", omittingEmptySubsequences: true)
        if !pendingBuffer.isEmpty && !pendingBuffer.hasSuffix("\n"), !lines.isEmpty {
            // 最后一段是不完整行，留在缓冲区等下一段
            pendingBuffer = String(lines.removeLast())
        } else {
            pendingBuffer = ""
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 兼容 mW / uW / W 三种单位输出（不同 macOS 版本/机型可能不同）
            if trimmed.contains("CPU Power") {
                latestCPU = parsePower(from: trimmed)
            } else if trimmed.contains("GPU Power") {
                latestGPU = parsePower(from: trimmed)
            } else if trimmed.contains("DRAM Power") {
                latestDRAM = parsePower(from: trimmed)
            }
        }
    }

    /// 空闲检查：app 关闭或用户关闭开关后停止拉取 → 60s 无请求终止 powermetrics，
    /// root 子进程不再常驻烧电。
    private func scheduleIdleCheckLocked() {
        let timer = DispatchSource.makeTimerSource(queue: powerQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            guard let process = metricsProcess else { return }
            if Date().timeIntervalSince(lastRequestAt) > idleTimeout {
                process.terminationHandler = nil  // 主动退出不触发重启
                metricsProcess = nil
                process.terminate()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    /// 解析功率行：支持 "1234 mW"、"1.23 W"、"1234 uW" 三种单位，返回瓦特
    private func parsePower(from line: String) -> Double {
        // 优先匹配 mW（最常见）
        if let range = line.range(of: "mW") {
            return extractValue(line, before: range.lowerBound, divisor: 1000.0)
        }
        // 其次匹配 uW（微瓦）
        if let range = line.range(of: "uW") {
            return extractValue(line, before: range.lowerBound, divisor: 1_000_000.0)
        }
        // 最后匹配独立的 W（不能匹配到 mW/uW 中的 W）
        // 用正则确保 W 前面不是 m/u
        if let range = line.range(of: #"(?<![mu])W"#, options: .regularExpression) {
            return extractValue(line, before: range.lowerBound, divisor: 1.0)
        }
        return 0
    }

    /// 从 line 中截取 unitRange 前面的最后一个数字，除以 divisor 转换为瓦特
    private func extractValue(_ line: String, before unitRange: String.Index, divisor: Double) -> Double {
        let beforeUnit = line[..<unitRange]
        if let value = beforeUnit.split(separator: " ").last,
           let v = Double(value.trimmingCharacters(in: .whitespaces)) {
            return v / divisor
        }
        return 0
    }
}

// 启动 helper，等待 XPC 调用
let helper = HelperTool()
helper.listener.resume()
RunLoop.main.run()
