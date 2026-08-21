import Foundation
import AppKit
import IOKit
import IOKit.ps
import os

private let batteryReaderLogger = Logger(subsystem: "com.batterybar", category: "BatteryReader")

/// XPC 协议（与 helper 共享）
@objc protocol HelperProtocol {
    // optional 以兼容尚未更新的旧版 helper
    @objc optional func getComponentPower(withReply reply: @escaping (NSDictionary) -> Void)
    @objc optional func getVersion(withReply reply: @escaping (String) -> Void)
}

final class BatteryReader: @unchecked Sendable {
    struct PowerSourceInfo {
        let level: Double
        let isCharging: Bool
        let isPluggedIn: Bool
        let timeRemaining: Int
        let capacity: Int
    }

    /// 静态信息缓存：机器型号、电池序列号、制造商等几乎不变的字段。
    /// 避免每秒 spawn system_profiler（耗时 1-3s）阻塞主线程。
    private struct StaticInfo {
        let hardwareModel: String?
        let serialFallback: String   // IORegistry 缺失时用 system_profiler 兜底
        let manufacturerFallback: String
    }
    private let staticInfoLock = NSLock()
    private var _staticInfo: StaticInfo?

    /// 后台预加载静态信息（machine model + serial/mfg 兜底）。
    /// 在 PowerSampler.start() 中调用，避免主线程阻塞。
    /// 加载完成后通过 `staticInfoLoaded` 通知外部触发 UI 刷新。
    private static let staticInfoLoadedNotification = Notification.Name("BatteryReaderStaticInfoLoaded")
    func prefetchStaticInfo() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // 已缓存则跳过
            self.staticInfoLock.lock()
            if self._staticInfo != nil {
                self.staticInfoLock.unlock()
                return
            }
            self.staticInfoLock.unlock()

            let model = self.readHardwareModel()
            var serialFallback = ""
            var mfgFallback = ""
            if let profile = self.readSystemProfilerBattery() {
                serialFallback = profile.serialNumber
                mfgFallback = profile.manufacturer
            }
            let info = StaticInfo(
                hardwareModel: model,
                serialFallback: serialFallback,
                manufacturerFallback: mfgFallback
            )
            self.staticInfoLock.lock()
            self._staticInfo = info
            self.staticInfoLock.unlock()
            batteryReaderLogger.info("Static info prefetched: model=\(model ?? "nil", privacy: .public), serial=\(serialFallback, privacy: .public)")
            NotificationCenter.default.post(name: Self.staticInfoLoadedNotification, object: nil)
        }
    }

    private var staticInfo: StaticInfo? {
        staticInfoLock.lock()
        defer { staticInfoLock.unlock() }
        return _staticInfo
    }

    private static let helperIdentifier = "com.batterybar.helper"
    private var helperConnection: NSXPCConnection?

    func readPowerSource() -> PowerSourceInfo {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              let first = list.first,
              let desc = IOPSGetPowerSourceDescription(info, first as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        else {
            return PowerSourceInfo(level: 0, isCharging: false, isPluggedIn: false, timeRemaining: -1, capacity: 0)
        }

        let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let level = maxCap > 0 ? Double(capacity) / Double(maxCap) * 100 : 0
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = powerSource == kIOPSACPowerValue
        let timeRemaining = desc[kIOPSTimeToEmptyKey] as? Int ?? -1

        return PowerSourceInfo(level: level, isCharging: isCharging, isPluggedIn: isPluggedIn, timeRemaining: timeRemaining, capacity: capacity)
    }

    func readBatteryInfo() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // macOS 27+：顶层 DesignCapacity 已移除，改放到 BatteryData 嵌套字典里
        let designCap = readInt(service, "DesignCapacity")
            ?? readNestedInt(service, "BatteryData", key: "DesignCapacity") ?? 0
        // 顶层 MaxCapacity 语义随系统版本变化：
        //   - 旧系统：mAh（>1000）
        //   - macOS 27+：健康度百分比（≤100）
        let maxCapRaw = readInt(service, "MaxCapacity") ?? 100
        // 实际满充容量（mAh）：优先 BatteryData.FullChargeCapacity（macOS 27+），
        // 其次 FccComp1（部分旧系统），再退到旧版顶层 mAh 或百分比推算
        let fcc = readNestedInt(service, "BatteryData", key: "FullChargeCapacity")
            ?? readNestedInt(service, "BatteryData", key: "FccComp1")
        let actualMaxCap: Int
        if let fcc, fcc > 0 {
            actualMaxCap = fcc
        } else if maxCapRaw > 1000 {
            actualMaxCap = maxCapRaw
        } else if designCap > 0 {
            actualMaxCap = designCap * maxCapRaw / 100
        } else {
            actualMaxCap = 0
        }

        let cycles = readInt(service, "CycleCount") ?? 0
        let voltage = readDouble(service, "Voltage") ?? 0
        let amperage = readInt(service, "InstantAmperage") ?? readInt(service, "Amperage") ?? 0
        let temp = readDouble(service, "Temperature") ?? 0
        // IORegistry 顶层字段名实测：Serial / DeviceName（不是 SerialNumber / DeviceName）
        // DeviceName 是电池管理芯片型号（如 bq20z451），不是机器型号
        let batteryChipName = readString(service, "DeviceName") ?? ""
        var serial = readString(service, "Serial") ?? readString(service, "SerialNumber") ?? ""
        var mfg = readString(service, "Manufacturer") ?? ""
        let isCharging = readBool(service, "IsCharging")
        let externalConnected = readBool(service, "ExternalConnected")

        // Fallback：Apple Silicon 上 AppleSmartBattery 不暴露 Manufacturer/Serial，
        // 用缓存的 system_profiler 兜底（首次可能为空，等 prefetchStaticInfo 完成后填充）
        let cached = staticInfo
        if serial.isEmpty, let s = cached?.serialFallback, !s.isEmpty { serial = s }
        if mfg.isEmpty, let m = cached?.manufacturerFallback, !m.isEmpty { mfg = m }
        // Manufacturer 仍为空时兜底为 Apple Inc.（Apple Silicon 电池均由 Apple 制造）
        if mfg.isEmpty { mfg = "Apple Inc." }

        // 设备名称：优先用缓存的机器型号（MacBook Air + Apple M1）
        let hardwareModel = cached?.hardwareModel
        let deviceName: String
        if let hw = hardwareModel, !hw.isEmpty {
            // 组合显示：机器型号 (电池芯片型号)，便于用户识别
            deviceName = batteryChipName.isEmpty ? hw : "\(hw) · \(batteryChipName)"
        } else {
            deviceName = batteryChipName
        }

        let wattage: Double
        if externalConnected && !isCharging {
            wattage = readSystemPower() ?? (abs(voltage * Double(amperage)) / 1_000_000)
        } else {
            wattage = abs(voltage * Double(amperage)) / 1_000_000
        }

        let adapter = readAdapterInfo()

        return BatteryInfo(
            designCapacity: designCap,
            maxCapacity: actualMaxCap,
            cycleCount: cycles,
            serialNumber: serial,
            manufacturer: mfg,
            voltage: voltage,
            instantAmperage: Double(amperage),
            temperature: temp / 100.0,
            isCharging: isCharging,
            externalConnected: externalConnected,
            systemPower: wattage,
            deviceName: deviceName,
            chemistry: "Li-ion",
            adapterWatts: adapter.watts,
            adapterProtocol: adapter.protocolName
        )
    }

    // MARK: - system_profiler fallback

    /// system_profiler 解析得到的电池静态信息（仅在 IORegistry 缺失时兜底使用）
    private struct SystemProfilerBattery {
        let serialNumber: String
        let manufacturer: String
        let deviceName: String
        let cycleCount: Int
        let maxCapacity: Int
        let designCapacity: Int
    }

    /// 通过 `system_profiler SPPowerDataType -json` 读取电池静态信息。
    /// 仅 serialNumber/manufacturer 可靠；cycleCount/maxCapacity 作为备份。
    /// ⚠️ 耗时 1-3s，仅在 prefetchStaticInfo 中后台调用一次，不在 readBatteryInfo 中直接调用。
    private func readSystemProfilerBattery() -> SystemProfilerBattery? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let powerArray = json["SPPowerDataType"] as? [[String: Any]],
                  let power = powerArray.first(where: { ($0["_name"] as? String)?.contains("battery") ?? false }) else { return nil }

            // 真实 JSON 结构：serial/device_name 在 sppower_battery_model_info 嵌套字典里
            let modelInfo = power["sppower_battery_model_info"] as? [String: Any] ?? [:]
            let serial = modelInfo["sppower_battery_serial_number"] as? String ?? ""
            let deviceName = modelInfo["sppower_battery_device_name"] as? String ?? ""

            // system_profiler 不提供 manufacturer 字段，Apple Silicon 电池无此信息
            let mfg = "Apple Inc."

            let healthInfo = power["sppower_battery_health_info"] as? [String: Any] ?? [:]
            let cycleCount = healthInfo["sppower_battery_cycle_count"] as? Int ?? 0
            var maxCap = 0
            if let maxStr = healthInfo["sppower_battery_health_maximum_capacity"] as? String {
                maxCap = Int(maxStr.replacingOccurrences(of: "%", with: "")) ?? 0
            }

            return SystemProfilerBattery(
                serialNumber: serial,
                manufacturer: mfg,
                deviceName: deviceName,
                cycleCount: cycleCount,
                maxCapacity: maxCap,
                designCapacity: 0
            )
        } catch {
            return nil
        }
    }

    /// 通过 `system_profiler SPHardwareDataType -json` 读取机器型号与芯片型号。
    /// 返回组合字符串："MacBook Air (Apple M1)"。失败返回 nil。
    /// ⚠️ 耗时 1-3s，仅在 prefetchStaticInfo 中后台调用一次。
    private func readHardwareModel() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json["SPHardwareDataType"] as? [[String: Any]],
                  let hw = arr.first else { return nil }
            let machineName = hw["machine_name"] as? String ?? ""
            let chipType = hw["chip_type"] as? String ?? ""
            if machineName.isEmpty && chipType.isEmpty { return nil }
            if chipType.isEmpty { return machineName }
            if machineName.isEmpty { return chipType }
            return "\(machineName) (\(chipType))"
        } catch {
            return nil
        }
    }

    // MARK: - 电源适配器 / 充电协议

    /// 电源适配器信息
    struct AdapterInfo {
        let watts: Double           // 适配器额定功率 (W)
        let volts: Double           // 当前电压 (V)
        let amps: Double            // 当前电流 (A)
        let protocolName: String    // 充电协议: "USB-PD", "USB-C", "MagSafe", "未知", "未连接"
        let isConnected: Bool
    }

    /// 读取电源适配器/充电协议信息。
    /// Apple Silicon 上 AppleSmartBattery 节点携带 AdapterDetails 字典
    /// （含 Watts/AdapterVoltage/Current）和 FedDetails（PD 协议版本）。
    func readAdapterInfo() -> AdapterInfo {
        // 方式1: AppleSmartBattery（实测含 AdapterDetails 和 FedDetails）
        let smartBattery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if smartBattery != 0 {
            defer { IOObjectRelease(smartBattery) }
            if let info = extractAdapterDetails(from: smartBattery) {
                return info
            }
        }

        // 方式2: AppleTypeCPUPMU
        let pmuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleTypeCPUPMU"))
        if pmuService != 0 {
            defer { IOObjectRelease(pmuService) }
            if let info = extractAdapterDetails(from: pmuService) {
                return info
            }
        }

        // 方式3: AppleACAdapter
        let adapterService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleACAdapter"))
        if adapterService != 0 {
            defer { IOObjectRelease(adapterService) }
            if let info = extractAdapterDetails(from: adapterService) {
                return info
            }
        }

        // Fallback
        let ps = readPowerSource()
        return AdapterInfo(
            watts: 0,
            volts: 0,
            amps: 0,
            protocolName: ps.isPluggedIn ? "未知" : "未连接",
            isConnected: ps.isPluggedIn
        )
    }

    /// 从 IORegistry 节点中尝试多种字段名抽取适配器参数。
    /// 实测 IORegistry 的 AdapterDetails 字典：
    ///   - Watts: 直接是瓦特数（如 45）
    ///   - AdapterVoltage: 单位 mV（如 20000 = 20V）
    ///   - Current: 单位 mA（如 2250 = 2.25A）
    ///   - UsbHvcMenu: PD 电压档位列表
    /// FedDetails 数组含 FedPdSpecRevision（PD 协议版本）
    private func extractAdapterDetails(from service: io_registry_entry_t) -> AdapterInfo? {
        // 优先：AdapterDetails 字典
        if let dict = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] {
            let watts = extractDouble(from: dict, keys: ["Watts", "AdapterWatts", "RatedPower"]) ?? 0
            // AdapterVoltage 单位 mV，转 V
            let voltsMv = extractDouble(from: dict, keys: ["AdapterVoltage", "Voltage", "Volts"]) ?? 0
            let volts = voltsMv >= 1000 ? voltsMv / 1000.0 : voltsMv
            // Current 单位 mA，转 A
            let ampsMa = extractDouble(from: dict, keys: ["Current", "Amps", "Amperage"]) ?? 0
            let amps = ampsMa >= 1000 ? ampsMa / 1000.0 : ampsMa

            if watts > 0 || volts > 0 || amps > 0 {
                // 从 UsbHvcMenu 判断是否 PD 协议，FedDetails 含 PD 版本
                var protocolName = "USB-PD"
                if let fedDetails = IORegistryEntryCreateCFProperty(service, "FedDetails" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]],
                   let firstFed = fedDetails.first(where: { ($0["FedPdSpecRevision"] as? Int ?? 0) > 0 }),
                   let pdRev = firstFed["FedPdSpecRevision"] as? Int {
                    protocolName = pdRev >= 3 ? "USB-PD 3.0" : (pdRev >= 2 ? "USB-PD 2.0" : "USB-PD")
                }
                batteryReaderLogger.info("Adapter: watts=\(watts), volts=\(volts), amps=\(amps), protocol=\(protocolName, privacy: .public)")
                return AdapterInfo(watts: watts, volts: volts, amps: amps,
                                   protocolName: protocolName, isConnected: true)
            }
            batteryReaderLogger.info("Adapter: AdapterDetails dict exists but all values are 0")
        } else {
            batteryReaderLogger.info("Adapter: AdapterDetails property not found")
        }

        // 次选：扁平字段
        let watts = readDouble(service, "Watts")
            ?? readDouble(service, "AdapterWatts")
            ?? Double(readInt(service, "Watts") ?? 0)
        let volts = readDouble(service, "Voltage")
            ?? readDouble(service, "Volts")
            ?? Double(readInt(service, "Voltage") ?? 0)
        let amps = readDouble(service, "Current")
            ?? readDouble(service, "Amperage")
            ?? Double(readInt(service, "Current") ?? 0)

        if watts > 0 || volts > 0 || amps > 0 {
            batteryReaderLogger.info("Adapter(flat): watts=\(watts), volts=\(volts), amps=\(amps)")
            return AdapterInfo(watts: watts, volts: volts, amps: amps,
                               protocolName: "USB-PD", isConnected: true)
        }
        return nil
    }

    /// 从字典中按候选键名抽取数值（兼容 Double/Int/NSNumber）。
    private func extractDouble(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            if let v = dict[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    private func readSystemPower() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        if let adapterPower = readNestedDouble(service, "BatteryData", key: "AdapterPower") {
            return adapterPower
        }
        if let sysPower = readNestedDouble(service, "BatteryData", key: "SystemPower") {
            return sysPower
        }
        return nil
    }

    func readComponentPower() -> ComponentPower {
        // 优先通过 XPC helper（root 权限）读取，powermetrics 需要 root 才能输出 cpu_power/gpu_power
        // 注意：如果 helper 是旧版（无 getComponentPower 方法），@objc optional 调用会被跳过，
        // 所以必须用带超时的 semaphore.wait，否则会永久阻塞采样线程。
        if isHelperInstalled() && !needsHelperUpdate() {
            let connection = getHelperConnection()
            let semaphore = DispatchSemaphore(value: 0)
            var gotResult = false
            var result = ComponentPower(cpu: 0, gpu: 0, display: 0, other: 0, dram: 0)

            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                batteryReaderLogger.error("ComponentPower XPC error")
                semaphore.signal()
            }) as? HelperProtocol

            if let proxy = proxy {
                proxy.getComponentPower? { dict in
                    result = ComponentPower(
                        cpu: dict["cpu"] as? Double ?? 0,
                        gpu: dict["gpu"] as? Double ?? 0,
                        display: 0,
                        other: 0,
                        dram: dict["dram"] as? Double ?? 0
                    )
                    gotResult = true
                    semaphore.signal()
                }
                // 超时 3 秒，避免旧 helper 卡死采样线程
                _ = semaphore.wait(timeout: .now() + 3)
                batteryReaderLogger.info("ComponentPower: gotResult=\(gotResult), cpu=\(result.cpu), gpu=\(result.gpu), dram=\(result.dram)")
                if gotResult {
                    return result
                }
            }
        } else {
            batteryReaderLogger.info("ComponentPower: helper not installed or needs update, skipping")
        }

        // Fallback: 直接调用（无 root 权限，返回 0）
        return ComponentPower(cpu: 0, gpu: 0, display: 0, other: 0, dram: 0)
    }

    /// 估算屏幕功耗 (W)
    ///
    /// 屏幕功耗无法直接从 IORegistry 读取（需要 IOReport framework，过于复杂），
    /// 这里采用估算方式：基础功耗 + 亮度系数。
    /// 参考 Apple Silicon MacBook 实测：
    ///   - MacBook Air (13"): 基础 1.5W + 亮度系数 (0-100% ≈ 0-2.5W)
    ///   - MacBook Pro (14"): 基础 2.0W + 亮度系数 (0-100% ≈ 0-3.0W)
    ///   - MacBook Pro (16"): 基础 2.5W + 亮度系数 (0-100% ≈ 0-4.0W)
    /// 此处采用通用简化模型：基础 1.5W + 亮度 × 2.5W。
    func estimateDisplayPower() -> Double {
        var brightness: Float = 0.7 // 默认假设 70% 亮度

        // 通过 IOKit 读取主显示器亮度 (0.0-1.0)
        // kIODisplayBrightnessKey = "brightness"
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &brightness)
        }

        let basePower = 1.5
        let brightnessPower = Double(brightness) * 2.5
        return basePower + brightnessPower
    }

    // 健康度缓存：用 NSLock 保护，避免数据竞争
    // nonisolated(unsafe) 已由 NSLock 保证访问安全
    private static let healthCacheLock = NSLock()
    private nonisolated(unsafe) static var _cachedHealthPercent: Double?
    private nonisolated(unsafe) static var _healthCacheTime: Date?

    func readSystemHealthPercent() -> Double {
        // 先检查缓存（60s 内复用）
        Self.healthCacheLock.lock()
        let cached = Self._cachedHealthPercent
        let cacheTime = Self._healthCacheTime
        Self.healthCacheLock.unlock()
        if let c = cached, let t = cacheTime, Date().timeIntervalSince(t) < 60 {
            return c
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let power = (json["SPPowerDataType"] as? [[String: Any]])?.first,
               let healthInfo = power["sppower_battery_health_info"] as? [String: Any],
               let healthStr = healthInfo["sppower_battery_health_maximum_capacity"] as? String,
               let percent = Double(healthStr.replacingOccurrences(of: "%", with: "")) {
                Self.healthCacheLock.lock()
                Self._cachedHealthPercent = percent
                Self._healthCacheTime = Date()
                Self.healthCacheLock.unlock()
                return percent
            }
        } catch {}

        if let info = readBatteryInfo(), info.designCapacity > 0 {
            return Double(info.maxCapacity) / Double(info.designCapacity) * 100
        }
        return 100
    }

    // MARK: - Helper XPC 连接

    /// 获取 helper XPC 连接
    private func getHelperConnection() -> NSXPCConnection {
        if let existing = helperConnection {
            return existing
        }

        let connection = NSXPCConnection(machServiceName: Self.helperIdentifier, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            self?.helperConnection = nil
        }
        connection.resume()
        helperConnection = connection
        return connection
    }

    /// 重置 XPC 连接（安装新 helper 后调用，确保连接到新进程）
    func resetHelperConnection() {
        if let conn = helperConnection {
            conn.invalidate()
            helperConnection = nil
        }
    }

    /// 检查 helper 是否已安装
    func isHelperInstalled() -> Bool {
        let path = "/Library/PrivilegedHelperTools/com.batterybar.helper"
        return FileManager.default.fileExists(atPath: path)
    }

    /// 当前要求的 helper 版本（不匹配则需重新安装）
    /// 4.0：powermetrics 从每次调用 spawn 改为懒启动常驻流式进程 + XPC 调用方校验
    private static let requiredHelperVersion = "4.0"

    /// 检查已安装的 helper 版本是否满足要求
    /// 返回 true 表示需要更新（版本不匹配或无法通信）
    func needsHelperUpdate() -> Bool {
        guard isHelperInstalled() else { return true }

        // 通过 XPC 调用 getVersion，带超时保护
        let connection = getHelperConnection()
        let semaphore = DispatchSemaphore(value: 0)
        var version: String? = nil

        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            // error handler 信号
            semaphore.signal()
        }) as? HelperProtocol

        proxy?.getVersion? { v in
            version = v
            semaphore.signal()
        }

        // 等待最多 2 秒
        _ = semaphore.wait(timeout: .now() + 2)

        // version 为 nil：要么旧版 helper 没 getVersion 方法（optional 被跳过），
        // 要么 XPC 连接失败。两者都需要重新安装
        if let v = version {
            batteryReaderLogger.info("Helper version: \(v), required: \(Self.requiredHelperVersion)")
            return v != Self.requiredHelperVersion
        } else {
            batteryReaderLogger.info("Helper version check: cannot get version, update needed")
            return true
        }
    }

    /// 安装 helper（首次需要管理员密码，app 内自动触发）
    /// 如果已安装但版本旧，也会触发重新安装
    @discardableResult
    func installHelperIfNeeded() -> Bool {
        // 已安装且版本匹配，无需操作
        if isHelperInstalled() && !needsHelperUpdate() { return true }

        let helperPath: String
        if let bundledPath = Bundle.main.path(forResource: "BatteryBarHelper", ofType: nil) {
            helperPath = bundledPath
        } else if let envPath = ProcessInfo.processInfo.environment["BATTERYBAR_HELPER_PATH"],
                  FileManager.default.fileExists(atPath: envPath) {
            // 仅开发调试用
            helperPath = envPath
        } else {
            batteryReaderLogger.error("Helper binary not found in app bundle. Ensure build-app.sh was used.")
            return false
        }
        return installHelper(from: helperPath)
    }

    /// 执行安装
    private func installHelper(from helperPath: String) -> Bool {
        let helperID = "com.batterybar.helper"
        let installPath = "/Library/PrivilegedHelperTools/\(helperID)"
        let plistPath = "/Library/LaunchDaemons/\(helperID).plist"

        // 先写 plist 到临时文件
        let tempPlist = FileManager.default.temporaryDirectory.appendingPathComponent("\(helperID).plist")
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(helperID)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(helperID)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """

        do {
            try plistContent.write(to: tempPlist, atomically: true, encoding: .utf8)
        } catch {
            batteryReaderLogger.error("Failed to write plist: \(error.localizedDescription)")
            return false
        }

        // 用 osascript 请求管理员权限执行安装
        // 顺序很重要：先 bootout 杀旧进程释放文件锁，再 cp 覆盖二进制，最后 bootstrap 启动新进程
        let script = """
        do shell script "mkdir -p /Library/PrivilegedHelperTools && (launchctl bootout system/\(helperID) 2>/dev/null || true) && sleep 1 && cp '\(helperPath)' '\(installPath)' && chown root:wheel '\(installPath)' && chmod 755 '\(installPath)' && cp '\(tempPlist.path)' '\(plistPath)' && chown root:wheel '\(plistPath)' && chmod 644 '\(plistPath)' && sleep 1 && launchctl bootstrap system/ '\(plistPath)'" with administrator privileges with prompt "BatteryBar 需要安装后台服务以读取 CPU/GPU 分项功耗"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempPlist)
            if task.terminationStatus == 0 {
                // 等待新 helper 启动
                Thread.sleep(forTimeInterval: 2.0)
                // 重置 XPC 连接，确保后续调用连接到新进程
                resetHelperConnection()
                return true
            }
        } catch {
            batteryReaderLogger.error("Failed to install helper: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempPlist)
        }
        return false
    }

    /// 卸载 helper：bootout 停止 root 守护进程并删除二进制与 plist（弹一次管理员密码框）。
    /// 返回 false 表示用户取消密码框或卸载失败（守护进程保留，但 app 侧不再调用；
    /// helper 4.0 起 powermetrics 有 60s 空闲自停，保留也不产生持续开销）。
    @discardableResult
    func uninstallHelper() -> Bool {
        let installPath = "/Library/PrivilegedHelperTools/\(Self.helperIdentifier)"
        let plistPath = "/Library/LaunchDaemons/\(Self.helperIdentifier).plist"

        // 已不在则无需提权
        guard FileManager.default.fileExists(atPath: installPath)
            || FileManager.default.fileExists(atPath: plistPath) else {
            resetHelperConnection()
            return true
        }

        let script = """
        do shell script "(launchctl bootout system/\(Self.helperIdentifier) 2>/dev/null || true) && rm -f '\(installPath)' '\(plistPath)'" with administrator privileges with prompt "BatteryBar 需要移除后台服务"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                resetHelperConnection()
                batteryReaderLogger.info("Helper uninstalled")
                return true
            }
            batteryReaderLogger.error("Helper uninstall cancelled or failed")
            return false
        } catch {
            batteryReaderLogger.error("Failed to uninstall helper: \(error.localizedDescription)")
            return false
        }
    }

    /// 打开系统电池设置
    func openBatterySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - IORegistry helpers

    private func readInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    private func readDouble(_ entry: io_registry_entry_t, _ key: String) -> Double? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double
    }

    private func readString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func readBool(_ entry: io_registry_entry_t, _ key: String) -> Bool {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    private func readNestedInt(_ entry: io_registry_entry_t, _ dict: String, key: String) -> Int? {
        guard let dict = IORegistryEntryCreateCFProperty(entry, dict as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict[key] as? Int
    }

    private func readNestedDouble(_ entry: io_registry_entry_t, _ dict: String, key: String) -> Double? {
        guard let dict = IORegistryEntryCreateCFProperty(entry, dict as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict[key] as? Double
    }
}

struct ComponentPower {
    let cpu: Double
    let gpu: Double
    let display: Double
    let other: Double
    let dram: Double

    var total: Double { cpu + gpu + display + other + dram }
}
