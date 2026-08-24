import Foundation

/// 实时遥测的统一轻量质量语义。
///
/// 不变量（冻结口径，不得改变统计语义）：
/// - `value` 可选：nil 表示本次读取不可用；`.some(0)` 是合法值，
///   必须与「不可读」可区分。
/// - 同值重复读取只更新 `readAt`，不更新 `changedAt`；
///   归一化值变化（含 available↔unavailable 切换）才更新 `changedAt`。
/// - `readAt` 是 App 实际完成读取的时间；`sourceSampleAt` 仅当底层明确提供
///   硬件采样时间时填写——目前只有 powermetrics 提供真实时间；
///   IORegistry / IOPS 没有可靠硬件时间戳，必须保持 nil，
///   不得用 App 读取时间冒充传感器采样时间。
/// - `stableFor` 只解释为「App 观察到数值持续未变」，
///   不能写成「传感器多久未更新」。
struct TelemetrySample<Value: Equatable>: Equatable {
    var value: Value?
    var availability: TelemetryAvailability
    var source: TelemetrySource
    var isEstimated: Bool
    /// App 完成本次读取的时刻
    var readAt: Date
    /// App 首次观察到当前归一化值的时刻
    var changedAt: Date
    /// 底层明确提供的硬件采样时间；无则保持 nil
    var sourceSampleAt: Date?

    static func initial(
        _ value: Value?,
        source: TelemetrySource,
        isEstimated: Bool = false,
        at readAt: Date,
        sourceSampleAt: Date? = nil
    ) -> TelemetrySample {
        TelemetrySample(
            value: value,
            availability: value == nil ? .unavailable : .available,
            source: source,
            isEstimated: isEstimated,
            readAt: readAt,
            changedAt: readAt,
            sourceSampleAt: Self.sanitizedSourceSampleAt(sourceSampleAt, source: source)
        )
    }

    /// 记录一次新观测。同值只推进 readAt；值变化推进 changedAt。
    mutating func observe(
        _ newValue: Value?,
        source: TelemetrySource,
        isEstimated: Bool = false,
        readAt: Date,
        sourceSampleAt: Date? = nil
    ) {
        let normalizedSampleAt = Self.sanitizedSourceSampleAt(sourceSampleAt, source: source)
        self.readAt = readAt
        if newValue != value {
            value = newValue
            changedAt = readAt
        }
        self.availability = newValue == nil ? .unavailable : .available
        self.source = source
        self.isEstimated = isEstimated
        self.sourceSampleAt = normalizedSampleAt
    }

    /// 「App 观察到数值持续未变」的时长。now 必须不早于 changedAt；
    /// 时钟回拨等异常按 0 处理。
    func stableFor(asOf now: Date) -> TimeInterval {
        let interval = now.timeIntervalSince(changedAt)
        return interval > 0 ? interval : 0
    }

    /// 只有 powermetrics 明确提供硬件时间戳；其余来源强制 nil。
    private static func sanitizedSourceSampleAt(_ raw: Date?, source: TelemetrySource) -> Date? {
        guard source == .powermetrics else { return nil }
        return raw
    }
}

enum TelemetryAvailability: String, Equatable {
    case available
    case unavailable
}

/// 遥测来源。至少区分到能解释同一字段为什么会有不同口径与可信度。
enum TelemetrySource: String, Equatable {
    case ioPowerSources = "IOPowerSources"
    case telemetrySystemLoad = "PowerTelemetry.SystemLoad"
    case batteryDataSystemPower = "BatteryData.SystemPower"
    case batteryPowerTelemetry = "PowerTelemetry/BatteryData.BatteryPower"
    case voltageCurrentDerived = "Voltage×CurrentDerived"
    case smartBatteryTemperature = "SmartBatteryTemperature"
    case smartBatteryPackTemperature = "SmartBatteryPackTemperature"
    case processInfo = "ProcessInfo"
    case displayIOKit = "DisplayIOKit"
    case powermetrics = "powermetrics"
    case mixed = "mixed"
    case unavailable = "unavailable"

    var displayName: String { rawValue }
}
