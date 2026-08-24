import Foundation
import AppKit
import IOKit
import IOKit.ps
import Security
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

    /// 同一轮采样的 IOPS 与 IORegistry 结果。调用方必须消费这一个快照，避免先后
    /// 两次读取跨过插拔边界，也避免每秒重复调用 IOPSCopyPowerSourcesInfo。
    struct BatteryReading {
        let powerSource: PowerSourceInfo
        let batteryInfo: BatteryInfo?
        /// 各字段的真实来源（provenance）
        let provenance: ReadingProvenance
        /// App 实际完成本轮读取的时刻。IORegistry/IOPS 不提供硬件时间戳，
        /// 这是唯一可信的「读取于」口径。
        let readAt: Date

        /// 可信系统负载（与 BatterySnapshot.trustedSystemLoad 同一冻结规则）：
        /// 实测遥测独立可信；估算负载只在明确离电时可信。
        var trustedSystemLoad: Double? {
            guard let info = batteryInfo, info.systemPowerAvailable, info.systemPower > 0 else { return nil }
            if !info.systemPowerIsEstimated { return info.systemPower }
            return info.externalConnected == false ? info.systemPower : nil
        }

        /// 电池功率方向通道（冻结规则）：
        /// 1. 接电且充电、功率可用 → charge；
        /// 2. 明确离电且未充电、功率可用 → discharge；
        /// 3. 接电未充电、状态自相矛盾（如离电却在充电）、来源未知或功率不可用 → unknown；
        /// 4. unknown 不累计任何一侧的 seconds/Wh。
        var batteryChannel: WindowTelemetryAggregator.BatteryChannel {
            guard let info = batteryInfo, info.batteryPowerAvailable else { return .unknown }
            switch (info.externalConnected, info.isCharging) {
            case (true, true):
                return .charge(info.batteryPower)
            case (false, false):
                return .discharge(info.batteryPower)
            case (true, false), (false, true):
                // 接电未充电（满电保持/优化充电暂停/80% 上限）与矛盾状态
                // 都不得进入任何一侧积分
                return .unknown
            }
        }
    }

    /// 一轮读取中关键字段的来源标注。IORegistry 没有硬件时间戳，
    /// 因此这里没有 sourceSampleAt 字段——App 读取时间不得冒充传感器时间。
    struct ReadingProvenance: Equatable {
        var systemLoadSource: TelemetrySource = .unavailable
        var systemLoadIsEstimated: Bool = true
        var batteryPowerSource: TelemetrySource = .unavailable
        /// 温度来源；nil 表示本轮温度不可读
        var temperatureSource: TelemetrySource?

        static let empty = ReadingProvenance()
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

    /// 适配器额定信息在插拔之间基本不变；缓存可避免每秒重复遍历三类 IORegistry 服务。
    private let adapterCacheLock = NSLock()
    private var adapterCache: (value: AdapterInfo, checkedAt: Date)?
    private let adapterCacheTTL: TimeInterval = 30

    /// 后台预加载静态信息（machine model + serial/mfg 兜底）。
    /// 在 PowerSampler.start() 中调用，避免主线程阻塞。
    /// 加载完成后通过 `staticInfoLoaded` 通知外部触发 UI 刷新。
    private static let staticInfoLoadedNotification = Notification.Name("BatteryReaderStaticInfoLoaded")
    func prefetchStaticInfo(includeBatteryFallback: Bool = true) {
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
            if includeBatteryFallback, let profile = self.readSystemProfilerBattery() {
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
            batteryReaderLogger.info("Static info prefetched: model=\(model ?? "nil", privacy: .public), serial=\(serialFallback, privacy: .private(mask: .hash))")
            NotificationCenter.default.post(name: Self.staticInfoLoadedNotification, object: nil)
        }
    }

    private var staticInfo: StaticInfo? {
        staticInfoLock.lock()
        defer { staticInfoLock.unlock() }
        return _staticInfo
    }

    private static let helperIdentifier = "com.batterybar.helper"
    private let helperConnectionLock = NSLock()
    private var helperConnection: NSXPCConnection?
    private var helperConnectionGeneration: UInt = 0
    private let helperStatusLock = NSLock()
    private var helperReadyCache: (ready: Bool, checkedAt: Date)?
    private let helperStatusTTL: TimeInterval = 300

    func readPowerSource() -> PowerSourceInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              !list.isEmpty
        else {
            return nil
        }

        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0 as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        }
        guard let desc = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }) ?? descriptions.first,
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
              let maxCap = desc[kIOPSMaxCapacityKey] as? Int,
              maxCap > 0,
              capacity >= 0 else { return nil }

        let level = min(100, max(0, Double(capacity) / Double(maxCap) * 100))
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = powerSource == kIOPSACPowerValue
        let timeRemaining = (isCharging
            ? desc[kIOPSTimeToFullChargeKey] as? Int
            : desc[kIOPSTimeToEmptyKey] as? Int) ?? -1

        return PowerSourceInfo(level: level, isCharging: isCharging, isPluggedIn: isPluggedIn, timeRemaining: timeRemaining, capacity: capacity)
    }

    /// 返回 nil 表示本轮 IOPS 读取失败：调用方必须保留上次状态，
    /// 不能把失败合成为 0%/离电污染插拔状态机。
    func readBatteryReading() -> BatteryReading? {
        guard let powerSource = readPowerSource() else { return nil }
        let (info, provenance) = readBatteryInfoWithProvenance(powerSource: powerSource)
        // readAt 在本轮 IOPS + IORegistry 全部读取完成后取得：
        // 它是「App 完成读取」的时刻，不是传感器采样时间（IORegistry 无硬件时间戳）。
        return BatteryReading(
            powerSource: powerSource,
            batteryInfo: info,
            provenance: info == nil ? .empty : provenance,
            readAt: Date()
        )
    }

    func readBatteryInfo() -> BatteryInfo? {
        readBatteryInfoWithProvenance(powerSource: readPowerSource()).info
    }

    private func readBatteryInfoWithProvenance(powerSource: PowerSourceInfo?) -> (info: BatteryInfo?, provenance: ReadingProvenance) {
        var provenance = ReadingProvenance.empty
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, .empty) }
        defer { IOObjectRelease(service) }

        // macOS 27+：顶层 DesignCapacity 已移除，改放到 BatteryData 嵌套字典里
        // 新系统把温度等 pack 级数据移到了 AppleSmartBatteryPack/BatteryData；
        // 只匹配 AppleSmartBattery 会漏掉本机真实存在的传感器数据。
        let packService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        defer { if packService != 0 { IOObjectRelease(packService) } }
        // 同一轮只把大型嵌套字典从 IORegistry 复制一次；旧实现每取一个字段都会
        // 再次跨 IOKit 边界创建整份 CFDictionary，是前台 1 秒轮询的主要分配热点。
        let batteryData = readDictionary(service, "BatteryData")
        let packBatteryData = readDictionary(packService, "BatteryData")
        let telemetryData = readDictionary(service, "PowerTelemetryData")

        let designCap = Self.firstValidCapacity([
            readInt(service, "DesignCapacity"),
            dictionaryInt(batteryData, key: "DesignCapacity"),
            dictionaryInt(packBatteryData, key: "DesignCapacity"),
        ])
        // 顶层 MaxCapacity 语义随系统版本变化：
        //   - 旧系统：mAh（>1000）
        //   - macOS 27+：健康度百分比（≤100）
        let maxCapRaw = readInt(service, "MaxCapacity") ?? 100
        // 实际满充容量（mAh）：优先 BatteryData.FullChargeCapacity（macOS 27+），
        // 其次 FccComp1（部分旧系统），再退到旧版顶层 mAh 或百分比推算
        let fcc = Self.firstValidCapacity([
            dictionaryInt(batteryData, key: "FullChargeCapacity"),
            dictionaryInt(batteryData, key: "FccComp1"),
            dictionaryInt(packBatteryData, key: "FullChargeCapacity"),
            dictionaryInt(packBatteryData, key: "FccComp1"),
        ])
        let actualMaxCap: Int
        if fcc > 0 {
            actualMaxCap = fcc
        } else if maxCapRaw > 1000 {
            actualMaxCap = Self.normalizedCapacity(maxCapRaw)
        } else if designCap > 0 {
            actualMaxCap = Self.normalizedCapacity(designCap * maxCapRaw / 100)
        } else {
            actualMaxCap = 0
        }

        let cycles = Self.firstValidCycleCount([
            readInt(service, "CycleCount"),
            dictionaryInt(packBatteryData, key: "CycleCount"),
        ])
        let voltage = Self.firstValidDouble([
            readDouble(service, "Voltage"),
            dictionaryDouble(batteryData, key: "Voltage"),
            dictionaryDouble(packBatteryData, key: "Voltage"),
        ], normalize: Self.normalizedBatteryVoltage)
        let amperageCandidates = [
            readDouble(service, "InstantAmperage"),
            readDouble(service, "Amperage"),
            dictionaryDouble(batteryData, key: "InstantAmperage"),
            dictionaryDouble(batteryData, key: "Amperage"),
            dictionaryDouble(packBatteryData, key: "InstantAmperage"),
            dictionaryDouble(packBatteryData, key: "Amperage"),
        ].compactMap { $0 }
        let amperage = amperageCandidates.first(where: {
            $0.isFinite && abs($0) <= 30_000
        }).map(Self.normalizedBatteryCurrent) ?? 0
        // 温度来源必须如实区分 SmartBattery 与 Pack 节点；IORegistry 无硬件时间戳，
        // sourceSampleAt 恒为 nil（质量模型层面强制）。
        var temperature: Double = 0
        let smartBatteryTemperatureCandidates: [Double?] = [
            readDouble(service, "Temperature"),
            dictionaryDouble(batteryData, key: "Temperature"),
        ]
        if let value = Self.firstValidValue(smartBatteryTemperatureCandidates, normalize: Self.normalizedBatteryTemperature) {
            temperature = value
            provenance.temperatureSource = .smartBatteryTemperature
        } else {
            let packCandidates: [Double?] = [
                readDouble(packService, "Temperature"),
                dictionaryDouble(packBatteryData, key: "Temperature"),
                dictionaryDouble(packBatteryData, key: "VirtualTemperature"),
            ]
            if let value = Self.firstValidValue(packCandidates, normalize: Self.normalizedBatteryTemperature) {
                temperature = value
                provenance.temperatureSource = .smartBatteryPackTemperature
            }
        }
        // IORegistry 顶层字段名实测：Serial / DeviceName（不是 SerialNumber / DeviceName）
        // DeviceName 是电池管理芯片型号（如 bq20z451），不是机器型号
        let batteryChipName = readString(service, "DeviceName") ?? ""
        var serial = readString(service, "Serial") ?? readString(service, "SerialNumber") ?? ""
        var mfg = readString(service, "Manufacturer") ?? ""
        let isCharging = readOptionalBool(service, "IsCharging") ?? powerSource?.isCharging ?? false
        let externalConnected = readOptionalBool(service, "ExternalConnected") ?? powerSource?.isPluggedIn ?? false

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

        // 电池包功率必须区分「可信的有效 0W」与「没有读到功率」，不得用普通
        // Double=0 同时表达两者。来源选择（优先级/0 立即胜出/坏值跳过/V×I 兜底）
        // 见 BatteryPowerSelection（纯逻辑，冻结规则）。兼容哨兵 0 只允许进入
        // BatterySnapshot 兼容字段，不得进入质量模型或分钟积分。
        let batteryPowerResult = BatteryPowerSelection.resolve(
            directCandidates: [
                (dictionaryDouble(telemetryData, key: "BatteryPower"), .batteryPowerTelemetry),
                (dictionaryDouble(batteryData, key: "BatteryPower"), .batteryPowerTelemetry),
                (dictionaryDouble(packBatteryData, key: "BatteryPower"), .batteryPowerTelemetry),
            ],
            voltage: voltage,
            amperage: amperage
        )
        if batteryPowerResult.available {
            provenance.batteryPowerSource = batteryPowerResult.source
        }
        let batteryPower = batteryPowerResult.value
        let batteryPowerAvailable = batteryPowerResult.available

        // Apple Silicon 的 PowerTelemetryData 提供系统负载与适配器输入功率，单位 mW。
        // 旧实现把 batteryPower（充电时只是电池包净流入功率）标成“系统总功耗”，
        // 在接电且满电时会显示 0.x W，而机器真实负载通常仍有数瓦到十几瓦。
        let telemetrySystemLoad = Self.normalizedTelemetryMilliwatts(
            dictionaryDouble(telemetryData, key: "SystemLoad")
        )
        let telemetryInputPower = Self.normalizedTelemetryMilliwatts(
            dictionaryDouble(telemetryData, key: "SystemPowerIn")
        )

        let legacySystemPower = Self.firstValidDouble([
            dictionaryDouble(batteryData, key: "SystemPower"),
            dictionaryDouble(batteryData, key: "AdapterPower"),
        ], normalize: Self.normalizedTelemetryPower)
        let systemPower: Double
        let systemPowerAvailable: Bool
        let systemPowerIsEstimated: Bool
        if telemetrySystemLoad > 0 {
            systemPower = telemetrySystemLoad
            systemPowerAvailable = true
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .telemetrySystemLoad
            provenance.systemLoadIsEstimated = false
        } else if legacySystemPower > 0 {
            systemPower = legacySystemPower
            systemPowerAvailable = true
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .batteryDataSystemPower
            provenance.systemLoadIsEstimated = false
        } else if !externalConnected {
            // 离电时，电池包输出功率可作为整机负载的近似值（含转换损耗）。
            systemPower = batteryPower
            systemPowerAvailable = batteryPower > 0
            systemPowerIsEstimated = true
            provenance.systemLoadSource = provenance.batteryPowerSource == .voltageCurrentDerived
                ? .voltageCurrentDerived
                : .batteryPowerTelemetry
        } else {
            // 接电时不能用电池充电功率代替整机负载；宁可明确不可用，也不显示假精度。
            systemPower = 0
            systemPowerAvailable = false
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .unavailable
        }

        let adapter = cachedAdapterInfo(isConnected: externalConnected)

        return (
            BatteryInfo(
                designCapacity: designCap,
                maxCapacity: actualMaxCap,
                cycleCount: cycles,
                serialNumber: serial,
                manufacturer: mfg,
                voltage: voltage,
                instantAmperage: amperage,
                temperature: temperature,
                isCharging: isCharging,
                externalConnected: externalConnected,
                systemPower: systemPower,
                batteryPower: batteryPower,
                batteryPowerAvailable: batteryPowerAvailable,
                adapterInputPower: telemetryInputPower,
                systemPowerAvailable: systemPowerAvailable,
                systemPowerIsEstimated: systemPowerIsEstimated,
                deviceName: deviceName,
                chemistry: "Li-ion",
                adapterWatts: adapter.watts,
                adapterProtocol: adapter.protocolName
            ),
            provenance
        )
    }

    /// IORegistry 的 PowerTelemetryData 使用 mW；少数旧节点可能直接给 W。
    /// 统一为瓦特并拒绝无效/溢出哨兵值。
    static func normalizedTelemetryPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return 0 }
        let watts = raw > 250 ? raw / 1000.0 : raw
        guard watts > 0, watts < 500 else { return 0 }
        return watts
    }

    /// PowerTelemetryData 的单位由节点定义为 mW；显式换算避免小于 250mW 时被启发式误判为 W。
    static func normalizedTelemetryMilliwatts(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0, raw < 500_000 else { return 0 }
        let watts = raw / 1_000
        return watts > 0 && watts < 500 ? watts : 0
    }

    /// 电池包直接功率允许正负号（充入/放出），对外统一返回绝对瓦数。
    static func normalizedBatteryPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, abs(raw) > 0, abs(raw) < 500_000 else { return 0 }
        let watts = abs(raw) / 1_000
        return watts > 0 && watts < 500 ? watts : 0
    }

    /// IORegistry Temperature/VirtualTemperature 使用百分之一摄氏度；兼容少数直接给 °C 的节点。
    static func normalizedBatteryTemperature(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return 0 }
        let celsius = raw > 150 ? raw / 100 : raw
        return (celsius >= -20 && celsius <= 100) ? celsius : 0
    }

    static func normalizedBatteryVoltage(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw >= 5_000, raw <= 30_000 else { return 0 }
        return raw
    }

    static func normalizedBatteryCurrent(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, abs(raw) <= 30_000 else { return 0 }
        return raw
    }

    static func normalizedCapacity(_ raw: Int?) -> Int {
        guard let raw, raw > 0, raw <= 100_000 else { return 0 }
        return raw
    }

    static func normalizedCycleCount(_ raw: Int?) -> Int {
        guard let raw, raw >= 0, raw <= 10_000 else { return 0 }
        return raw
    }

    private static func firstValidCapacity(_ candidates: [Int?]) -> Int {
        for raw in candidates {
            let value = normalizedCapacity(raw)
            if value > 0 { return value }
        }
        return 0
    }

    private static func firstValidCycleCount(_ candidates: [Int?]) -> Int {
        for raw in candidates {
            let value = normalizedCycleCount(raw)
            if value > 0 { return value }
        }
        return 0
    }

    private static func firstValidDouble(
        _ candidates: [Double?],
        normalize: (Double?) -> Double
    ) -> Double {
        for raw in candidates {
            let value = normalize(raw)
            if value > 0 { return value }
        }
        return 0
    }

    /// 与 firstValidDouble 相同的候选顺序，但返回首个有效值本身（可能为 0 合法值由调用方处理）。
    private static func firstValidValue(
        _ candidates: [Double?],
        normalize: (Double?) -> Double
    ) -> Double? {
        for raw in candidates {
            let value = normalize(raw)
            if value > 0 { return value }
        }
        return nil
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
            protocolName: ps?.isPluggedIn == true ? "未知" : "未连接",
            isConnected: ps?.isPluggedIn == true
        )
    }

    private func cachedAdapterInfo(isConnected: Bool) -> AdapterInfo {
        guard isConnected else {
            adapterCacheLock.lock()
            adapterCache = nil
            adapterCacheLock.unlock()
            return AdapterInfo(
                watts: 0,
                volts: 0,
                amps: 0,
                protocolName: "未连接",
                isConnected: false
            )
        }

        adapterCacheLock.lock()
        let cached = adapterCache
        adapterCacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.checkedAt) < adapterCacheTTL {
            return cached.value
        }

        let refreshed = readAdapterInfo()
        adapterCacheLock.lock()
        adapterCache = (refreshed, Date())
        adapterCacheLock.unlock()
        return refreshed
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

    func readComponentPower() -> ComponentPower {
        // 优先通过 XPC helper（root 权限）读取，powermetrics 需要 root 才能输出 cpu_power/gpu_power
        // 注意：如果 helper 是旧版（无 getComponentPower 方法），@objc optional 调用会被跳过，
        // 所以必须用带超时的 semaphore.wait，否则会永久阻塞采样线程。
        if helperIsReady() {
            let connection = getHelperConnection()
            let semaphore = DispatchSemaphore(value: 0)
            var gotResult = false
            var result = ComponentPower(cpu: 0, gpu: 0, display: 0, other: 0, dram: 0,
                                        isAvailable: false, sampledAt: .distantPast)

            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                batteryReaderLogger.error("ComponentPower XPC error")
                semaphore.signal()
            }) as? HelperProtocol

            if let proxy = proxy {
                proxy.getComponentPower? { dict in
                    let cpu = Self.normalizedComponentPower(dict["cpu"] as? Double)
                    let gpu = Self.normalizedComponentPower(dict["gpu"] as? Double)
                    let dram = Self.normalizedComponentPower(dict["dram"] as? Double)
                    let sampleTime = dict["sampleTime"] as? Double ?? 0
                    let explicitAvailable = dict["available"] as? Bool
                    result = ComponentPower(
                        cpu: cpu,
                        gpu: gpu,
                        display: 0,
                        other: 0,
                        dram: dram,
                        isAvailable: explicitAvailable ?? (cpu > 0 || gpu > 0 || dram > 0),
                        sampledAt: sampleTime > 0 ? Date(timeIntervalSince1970: sampleTime) : Date()
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
        return ComponentPower(cpu: 0, gpu: 0, display: 0, other: 0, dram: 0,
                              isAvailable: false, sampledAt: .distantPast)
    }

    static func normalizedComponentPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw >= 0, raw < 500 else { return 0 }
        return raw
    }

    /// 主显示器亮度读取结果。brightness 为 nil 表示不可读取——
    /// 不得用任何默认亮度或瓦数模型填补。
    struct DisplayBrightnessReading {
        /// 归一化亮度 0...1；nil = 接口失败或数值越界（坏数据直接拒绝，不夹取）
        let brightness: Double?
        let readAt: Date
    }

    /// 读取主显示器亮度（0...1）。没有机型标定、HDR、内容与刷新率信息，
    /// 亮度不能换算成可信瓦数，因此只记录原始量本身。
    func readDisplayBrightness() -> DisplayBrightnessReading {
        let readAt = Date()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"))
        guard service != 0 else { return DisplayBrightnessReading(brightness: nil, readAt: readAt) }
        defer { IOObjectRelease(service) }
        var brightness: Float = 0
        guard IODisplayGetFloatParameter(service, 0, "brightness" as CFString, &brightness) == kIOReturnSuccess,
              brightness.isFinite, brightness >= 0, brightness <= 1
        else { return DisplayBrightnessReading(brightness: nil, readAt: readAt) }
        return DisplayBrightnessReading(brightness: Double(brightness), readAt: readAt)
    }

    // MARK: - 系统电池健康（system_profiler 口径）

    /// 健康度进程内缓存：避免重复 spawn system_profiler；
    /// 刷新节奏（小时级 TTL / 唤醒后）由 PowerSampler 决定，不进入采样路径。
    /// 解析与口径选择纯函数见 BatteryHealthMetric。
    private let healthCacheLock = NSLock()
    private var cachedSystemHealth: SystemHealthReading?

    /// 后台读取系统健康度。耗时 1–3s，只允许在 detached 任务中调用，
    /// 绝不进入 5/15 秒采样路径。60 秒进程内缓存防止重复 spawn。
    func readSystemHealth() -> SystemHealthReading? {
        healthCacheLock.lock()
        let cached = cachedSystemHealth
        healthCacheLock.unlock()
        if let cached, Date().timeIntervalSince(cached.readAt) < 60 {
            return cached
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
               let percent = BatteryHealthMetric.systemProfilerHealthPercent(json: json) {
                let reading = SystemHealthReading(percent: percent, readAt: Date())
                healthCacheLock.lock()
                cachedSystemHealth = reading
                healthCacheLock.unlock()
                return reading
            }
        } catch {}

        // 解析失败不缓存失败态：下次 TTL 到期重试；调用方负责回退口径。
        return nil
    }

    // MARK: - Helper XPC 连接

    /// 获取 helper XPC 连接
    private func getHelperConnection() -> NSXPCConnection {
        helperConnectionLock.lock()
        if let existing = helperConnection {
            helperConnectionLock.unlock()
            return existing
        }

        let connection = NSXPCConnection(machServiceName: Self.helperIdentifier, options: [])
        helperConnectionGeneration &+= 1
        let generation = helperConnectionGeneration
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            var invalidatedCurrentConnection = false
            self.helperConnectionLock.lock()
            if self.helperConnectionGeneration == generation {
                self.helperConnection = nil
                invalidatedCurrentConnection = true
            }
            self.helperConnectionLock.unlock()
            if invalidatedCurrentConnection {
                self.cacheHelperReady(false)
            }
        }
        connection.resume()
        helperConnection = connection
        helperConnectionLock.unlock()
        return connection
    }

    /// 重置 XPC 连接（安装新 helper 后调用，确保连接到新进程）
    func resetHelperConnection() {
        helperConnectionLock.lock()
        let connection = helperConnection
        helperConnection = nil
        helperConnectionGeneration &+= 1
        helperConnectionLock.unlock()
        connection?.invalidate()
        helperStatusLock.lock()
        helperReadyCache = nil
        helperStatusLock.unlock()
    }

    /// 检查 helper 是否已安装
    func isHelperInstalled() -> Bool {
        let path = "/Library/PrivilegedHelperTools/com.batterybar.helper"
        return FileManager.default.fileExists(atPath: path)
    }

    /// 当前要求的 helper 版本（不匹配则需重新安装）
    /// 5.0：Helper 调用方同时校验 bundle id 与安装时绑定的客户端 CDHash；
    /// launchd 改为按 XPC 请求启动，Helper 空闲后退出。
    private static let requiredHelperVersion = "5.0"

    /// 检查已安装的 helper 版本是否满足要求
    /// 返回 true 表示需要更新（版本不匹配或无法通信）
    func needsHelperUpdate() -> Bool {
        guard isHelperInstalled() else {
            cacheHelperReady(false)
            return true
        }

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
            let ready = v == Self.requiredHelperVersion
            cacheHelperReady(ready)
            return !ready
        } else {
            batteryReaderLogger.info("Helper version check: cannot get version, update needed")
            cacheHelperReady(false)
            return true
        }
    }

    /// 热路径只在缓存过期时检查文件与 helper 版本，正常情况下每次采样仅需一次取数 XPC。
    private func helperIsReady() -> Bool {
        helperStatusLock.lock()
        let cached = helperReadyCache
        helperStatusLock.unlock()
        if let cached, Date().timeIntervalSince(cached.checkedAt) < helperStatusTTL {
            return cached.ready
        }
        return !needsHelperUpdate()
    }

    private func cacheHelperReady(_ ready: Bool) {
        helperStatusLock.lock()
        helperReadyCache = (ready, Date())
        helperStatusLock.unlock()
    }

    /// 安装 helper（首次需要管理员密码，app 内自动触发）
    /// 如果已安装但版本旧，也会触发重新安装
    @discardableResult
    func installHelperIfNeeded() -> Bool {
        // 已安装且版本匹配，无需操作
        if isHelperInstalled() && !needsHelperUpdate() { return true }

        let helperPath: String
        if let bundledPath = validatedBundledHelperPath() {
            helperPath = bundledPath
        } else {
#if DEBUG
            if let envPath = ProcessInfo.processInfo.environment["BATTERYBAR_HELPER_PATH"],
               FileManager.default.fileExists(atPath: envPath) {
                // 仅 Debug 裸二进制开发使用；Release 构建绝不接受环境变量提供的 root payload。
                helperPath = envPath
            } else {
                batteryReaderLogger.error("Helper binary not found in app bundle. Ensure build-app.sh was used.")
                return false
            }
#else
            batteryReaderLogger.error("Helper binary not found in app bundle. Ensure build-app.sh was used.")
            return false
#endif
        }
        return installHelper(from: helperPath)
    }

    /// 只接受当前已签名 App Bundle 内、解析符号链接后仍位于 Resources 下的 Helper。
    /// 这既阻止 Release 环境变量替换 payload，也避免 bundle 内符号链接逃逸。
    private func validatedBundledHelperPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
              let rawURL = Bundle.main.url(forResource: "BatteryBarHelper", withExtension: nil)
        else { return nil }
        let helperURL = rawURL.resolvingSymlinksInPath()
        let resourcePrefix = resourceURL.path.hasSuffix("/") ? resourceURL.path : resourceURL.path + "/"
        guard helperURL.path.hasPrefix(resourcePrefix),
              FileManager.default.isExecutableFile(atPath: helperURL.path),
              staticCodeIsValid(at: Bundle.main.bundleURL),
              staticCodeIsValid(at: helperURL)
        else {
            batteryReaderLogger.error("Rejecting untrusted bundled Helper")
            return nil
        }
        return helperURL.path
    }

    private func staticCodeIsValid(at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    /// Helper 关闭时只比较磁盘代码签名哈希，不建立 XPC 连接、不触发 launchd。
    /// 用于提示遗留版本需要更新，同时保持“默认关闭 = 零 Helper 调用”。
    func dormantInstalledHelperNeedsUpdate() -> Bool {
        let installedURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.batterybar.helper")
        guard FileManager.default.fileExists(atPath: installedURL.path) else { return false }
        guard let bundledPath = validatedBundledHelperPath(),
              let installedHash = staticCodeCDHash(at: installedURL),
              let bundledHash = staticCodeCDHash(at: URL(fileURLWithPath: bundledPath))
        else { return true }
        return installedHash.caseInsensitiveCompare(bundledHash) != .orderedSame
    }

    private func staticCodeCDHash(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func currentExecutableCDHash() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return staticCodeCDHash(at: executableURL)
    }

    /// 执行安装
    private func installHelper(from helperPath: String) -> Bool {
        let helperID = "com.batterybar.helper"
        let installPath = "/Library/PrivilegedHelperTools/\(helperID)"
        let plistPath = "/Library/LaunchDaemons/\(helperID).plist"
        guard let authorizedClientCDHash = currentExecutableCDHash() else {
            batteryReaderLogger.error("Cannot bind Helper to the current signed executable")
            return false
        }

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
            <key>EnvironmentVariables</key>
            <dict>
                <key>BATTERYBAR_AUTHORIZED_CLIENT_CDHASH</key>
                <string>\(authorizedClientCDHash)</string>
            </dict>
        </dict>
        </plist>
        """

        // 用 osascript 请求管理员权限执行安装。所有动态路径都通过 argv 传入，再由
        // AppleScript 的 `quoted form of` 生成 shell 参数；禁止把路径直接插进命令字符串。
        // plist 内容也由提权 shell 直接写入最终路径，不经过可被同用户进程替换的临时文件。
        // 顺序很重要：先 bootout 杀旧进程释放文件锁，再 cp 覆盖二进制，最后 bootstrap 启动新进程。
        let script = """
        on run argv
            set helperSource to item 1 of argv
            set helperDestination to item 2 of argv
            set plistDestination to item 3 of argv
            set plistContents to item 4 of argv
            set authPrompt to item 5 of argv
            set shellCommand to "mkdir -p /Library/PrivilegedHelperTools && (launchctl bootout system/com.batterybar.helper 2>/dev/null || true) && sleep 1 && cp " & quoted form of helperSource & " " & quoted form of helperDestination & " && chown root:wheel " & quoted form of helperDestination & " && chmod 755 " & quoted form of helperDestination & " && /usr/bin/printf %s " & quoted form of plistContents & " > " & quoted form of plistDestination & " && chown root:wheel " & quoted form of plistDestination & " && chmod 644 " & quoted form of plistDestination & " && sleep 1 && launchctl bootstrap system/ " & quoted form of plistDestination
            do shell script shellCommand with administrator privileges with prompt authPrompt
        end run
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e", script, "--",
            helperPath,
            installPath,
            plistPath,
            plistContent,
            "\(AppBrand.displayName)需要安装后台服务以读取 CPU/GPU 分项功耗",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                // 等待新 helper 启动
                Thread.sleep(forTimeInterval: 2.0)
                // 重置 XPC 连接，确保后续调用连接到新进程
                resetHelperConnection()
                return true
            }
        } catch {
            batteryReaderLogger.error("Failed to install helper: \(error.localizedDescription)")
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
        do shell script "(launchctl bootout system/\(Self.helperIdentifier) 2>/dev/null || true) && rm -f '\(installPath)' '\(plistPath)'" with administrator privileges with prompt "\(AppBrand.displayName)需要移除后台服务"
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

    private func readOptionalBool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func readDictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        guard entry != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    private func dictionaryInt(_ dictionary: [String: Any]?, key: String) -> Int? {
        dictionary?[key] as? Int
    }

    private func dictionaryDouble(_ dictionary: [String: Any]?, key: String) -> Double? {
        dictionary?[key] as? Double
    }

}

struct ComponentPower {
    let cpu: Double
    let gpu: Double
    let display: Double
    let other: Double
    let dram: Double
    let isAvailable: Bool
    let sampledAt: Date

    var total: Double { cpu + gpu + display + other + dram }
}
