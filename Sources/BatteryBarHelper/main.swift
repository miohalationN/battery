import Foundation

/// XPC 协议
@objc protocol HelperProtocol {
    // 读取 CPU/GPU 功耗（通过 powermetrics，需 root 权限）
    func getComponentPower(withReply reply: @escaping (NSDictionary) -> Void)
    // 返回 helper 版本号（用于检测是否需要更新）
    func getVersion(withReply reply: @escaping (String) -> Void)
}

/// Privileged Helper — 以 root 权限常驻运行，通过 XPC 通信
class HelperTool: NSObject, NSXPCListenerDelegate {
    let listener: NSXPCListener

    override init() {
        self.listener = NSXPCListener(machServiceName: "com.batterybar.helper")
        super.init()
        self.listener.delegate = self
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

extension HelperTool: HelperProtocol {
    func getComponentPower(withReply reply: @escaping (NSDictionary) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["--samplers", "cpu_power,gpu_power,dram", "-n", "1", "-i", "100"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // 超时保护：powermetrics 正常 ~100ms 完成，超过 5s 视为卡死
        // Helper 是单线程 RunLoop，process.waitUntilExit() 阻塞会导致后续所有 XPC 调用无法处理
        var hasReplied = false
        let replyOnce: (NSDictionary) -> Void = { dict in
            guard !hasReplied else { return }
            hasReplied = true
            reply(dict)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            if process.isRunning {
                process.terminate()
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            var cpuPower: Double = 0
            var gpuPower: Double = 0
            var dramPower: Double = 0

            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 兼容 mW / W / uW 三种单位输出（不同 macOS 版本/机型可能不同）
                if trimmed.contains("CPU Power") {
                    cpuPower = parsePower(from: trimmed)
                }
                if trimmed.contains("GPU Power") {
                    gpuPower = parsePower(from: trimmed)
                }
                if trimmed.contains("DRAM Power") {
                    dramPower = parsePower(from: trimmed)
                }
            }

            replyOnce(["cpu": cpuPower, "gpu": gpuPower, "dram": dramPower])
        } catch {
            replyOnce(["cpu": 0.0, "gpu": 0.0, "dram": 0.0])
        }
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

    func getVersion(withReply reply: @escaping (String) -> Void) {
        reply("3.0")
    }
}

// 启动 helper，等待 XPC 调用
let helper = HelperTool()
helper.listener.resume()
RunLoop.main.run()
