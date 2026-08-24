import Foundation

/// 一个自然分钟窗口的 v5 聚合结果。全部字段语义冻结：
/// - 能量只来自可信来源的零阶保持积分，缺口不外推；
/// - `systemCoverage` / `temperatureCoverage` 是「有效时长 / 60 秒」，
///   有效零瓦计入覆盖，缺失不计入；
/// - 离散状态份额由状态切换时刻精确累计，不受连续量保持上限约束。
struct MinuteAggregate: Equatable {
    var windowStart: Date

    var systemEnergyWh: Double?
    var systemPowerAverage: Double?
    var systemPowerPeak: Double?
    var systemCoverage: Double

    var batteryChargeWh: Double
    var batteryChargeSeconds: TimeInterval
    var batteryDischargeWh: Double
    var batteryDischargeSeconds: TimeInterval

    var temperatureAverage: Double?
    var temperatureMaximum: Double?
    var temperatureCoverage: Double

    var screenOnFraction: Double
    var lowPowerModeFraction: Double
    var maximumThermalStateLabel: String?
    var maximumThermalStateOrdinal: Int?

    /// UI 是否可把能耗当作完整分钟指标展示（冻结阈值：覆盖率 ≥ 0.8）。
    var hasFullSystemMetric: Bool { systemCoverage >= 0.8 }
    /// 温度趋势是否允许连线（冻结阈值：覆盖率 ≥ 0.5）；最大值可保留但须附覆盖率。
    var hasUsableTemperatureTrend: Bool { temperatureCoverage >= 0.5 }
}

/// 分钟窗口遥测聚合器：纯逻辑、时间显式注入、常量内存（只保留当前窗口与
/// 最近一个完成窗口，不积累原始样本）。
///
/// 连续量（系统负载、电池充/放功率、温度）采用上一有效观测值零阶保持，
/// 单个样本最多保持 `min(30秒, 2×取得该样本时的预期间隔)`；超过部分视为缺口，
/// 严禁跨长时间无样本外推。负时间、乱序时间整条观测拒绝。
/// 睡眠开始调用 `truncateContinuity` 立即截断连续量；离散状态由通知驱动的
/// `setState` 按真实切换时刻精确累计。
struct WindowTelemetryAggregator {
    static let windowLength: TimeInterval = 60
    static let maximumHold: TimeInterval = 30

    enum BatteryChannel: Equatable {
        /// 接电且 isCharging==true：电池包净流入功率（瓦特）
        case charge(Double)
        /// 明确离电：电池包放出功率绝对值（瓦特）
        case discharge(Double)
        /// 电源方向未知：不得进入任何一侧积分
        case unknown
    }

    struct Observation {
        let date: Date
        /// 可信系统负载；nil 为缺口，`.some(0)` 是合法零瓦
        let trustedSystemLoad: Double?
        let batteryChannel: BatteryChannel
        /// 有效电池包温度；nil 表示本轮不可读
        let temperatureCelsius: Double?
        /// 取得本批样本时的预期间隔（前台 5s / 后台 15s），决定保持上限
        let expectedInterval: TimeInterval

        init(
            date: Date,
            trustedSystemLoad: Double?,
            batteryChannel: BatteryChannel,
            temperatureCelsius: Double?,
            expectedInterval: TimeInterval
        ) {
            self.date = date
            self.trustedSystemLoad = trustedSystemLoad
            self.batteryChannel = batteryChannel
            self.temperatureCelsius = temperatureCelsius
            self.expectedInterval = expectedInterval
        }
    }

    /// 单个连续量的零阶保持状态。样本有效期 = 取样时刻 + 保持上限；
    /// attributedTo 记录已并入窗口累计的时间推进位置。
    private struct HoldStream {
        var value: Double?
        var validFrom: Date
        var validUntil: Date
        var attributedTo: Date

        static let empty = HoldStream(value: nil, validFrom: .distantPast, validUntil: .distantPast, attributedTo: .distantPast)
    }

    private struct DiscreteSpan {
        var state: Bool?
        var spanStart: Date
        var secondsInWindow: Double

        static let initial = DiscreteSpan(state: nil, spanStart: .distantPast, secondsInWindow: 0)
    }

    private var windowStart: Date?
    private var systemStream = HoldStream.empty
    private var chargeStream = HoldStream.empty
    private var dischargeStream = HoldStream.empty
    private var temperatureStream = HoldStream.empty

    private var systemSeconds: TimeInterval = 0
    private var systemEnergyWh: Double = 0
    private var systemPeak: Double = 0
    private var chargeWh: Double = 0
    private var chargeSeconds: TimeInterval = 0
    private var dischargeWh: Double = 0
    private var dischargeSeconds: TimeInterval = 0
    private var temperatureSeconds: TimeInterval = 0
    private var temperatureWeightedSum: Double = 0
    private var temperatureMax: Double?

    private var screenSpan = DiscreteSpan.initial
    private var lowPowerSpan = DiscreteSpan.initial
    private var thermalOrdinalMax: Int?
    private var thermalLabelForMax: String?

    /// 全局单调游标：早于它的事件（观测、状态、截断）一律拒绝
    private(set) var timelineCursor: Date?
    private(set) var lastCompleted: MinuteAggregate?

    /// 记录一次成功基础读取。
    mutating func observe(_ observation: Observation) {
        guard observation.date >= (timelineCursor ?? .distantPast),
              observation.expectedInterval.isFinite,
              observation.expectedInterval > 0
        else { return }
        advanceWindows(through: observation.date)

        integrateContinuous(until: observation.date)
        install(observation, at: observation.date)
        timelineCursor = observation.date
    }

    /// 通知驱动的离散状态更新。nil 字段保持原状；切换按真实时刻精确累计。
    mutating func setState(
        screenOn: Bool? = nil,
        lowPowerMode: Bool? = nil,
        thermalStateOrdinal: Int? = nil,
        thermalStateLabel: String? = nil,
        at date: Date
    ) {
        guard date >= (timelineCursor ?? .distantPast) else { return }
        advanceWindows(through: date)
        closeDiscreteSpans(at: date)
        if let screenOn {
            screenSpan.state = screenOn
            screenSpan.spanStart = date
        }
        if let lowPowerMode {
            lowPowerSpan.state = lowPowerMode
            lowPowerSpan.spanStart = date
        }
        if let ordinal = thermalStateOrdinal, ordinal > (thermalOrdinalMax ?? Int.min) {
            thermalOrdinalMax = ordinal
            thermalLabelForMax = thermalStateLabel
        }
        timelineCursor = date
    }

    /// 睡眠开始：立即截断全部连续量（保持链清空），防止睡眠前功率延伸进睡眠窗口。
    /// 离散状态不受影响；screenOn 由调用方另行 setState(false)。
    mutating func truncateContinuity(at date: Date) {
        guard date >= (timelineCursor ?? .distantPast) else { return }
        advanceWindows(through: date)
        integrateContinuous(until: date)
        systemStream.value = nil
        chargeStream.value = nil
        dischargeStream.value = nil
        temperatureStream.value = nil
        timelineCursor = date
    }

    /// 取走最近完成的窗口聚合。只保留最近一个：
    /// 长时间无读取后跨越多个边界时旧窗口自然作废，不积累历史。
    mutating func takeCompletedAggregate() -> MinuteAggregate? {
        defer { lastCompleted = nil }
        return lastCompleted
    }

    // MARK: - 保持上限

    /// 单个连续样本的保持上限：min(30 秒, 2×预期间隔)。
    static func holdLimit(forExpectedInterval interval: TimeInterval) -> TimeInterval {
        min(maximumHold, 2 * interval)
    }

    static func floorToWindow(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / windowLength).rounded(.down) * windowLength)
    }

    // MARK: - 内部积分

    /// 从流中取出 [attributedTo, min(end, 有效期)) ∩ 当前窗口 的区间并推进游标；
    /// 样本到期后置空。返回 (值, 有效秒数)。
    /// static：避免「mutating 方法接收者 self 与 inout 属性重叠」的独占访问冲突。
    private static func consume(
        _ stream: inout HoldStream,
        until end: Date,
        windowStart: Date?
    ) -> (value: Double, seconds: TimeInterval)? {
        guard let value = stream.value else { return nil }
        let upper = min(end, stream.validUntil)
        let lower = max(stream.attributedTo, stream.validFrom, windowStart ?? .distantPast)
        defer {
            stream.attributedTo = max(stream.attributedTo, upper)
            if end >= stream.validUntil { stream.value = nil }
        }
        guard upper > lower else { return nil }
        return (value, upper.timeIntervalSince(lower))
    }

    private mutating func integrateContinuous(until end: Date) {
        let start = windowStart ?? .distantPast
        if let s = Self.consume(&systemStream, until: end, windowStart: start) {
            systemSeconds += s.seconds
            systemEnergyWh += s.value * s.seconds / 3600
            systemPeak = max(systemPeak, s.value)
        }
        if let s = Self.consume(&chargeStream, until: end, windowStart: start) {
            chargeSeconds += s.seconds
            chargeWh += s.value * s.seconds / 3600
        }
        if let s = Self.consume(&dischargeStream, until: end, windowStart: start) {
            dischargeSeconds += s.seconds
            dischargeWh += s.value * s.seconds / 3600
        }
        if let s = Self.consume(&temperatureStream, until: end, windowStart: start) {
            temperatureSeconds += s.seconds
            temperatureWeightedSum += s.value * s.seconds
            temperatureMax = max(temperatureMax ?? s.value, s.value)
        }
    }

    private mutating func install(_ observation: Observation, at date: Date) {
        let expiry = date.addingTimeInterval(Self.holdLimit(forExpectedInterval: observation.expectedInterval))
        systemStream = HoldStream(
            value: observation.trustedSystemLoad,
            validFrom: date, validUntil: expiry, attributedTo: date
        )
        switch observation.batteryChannel {
        case .charge(let watts):
            chargeStream = HoldStream(value: watts, validFrom: date, validUntil: expiry, attributedTo: date)
            dischargeStream = HoldStream.empty
        case .discharge(let watts):
            chargeStream = HoldStream.empty
            dischargeStream = HoldStream(value: watts, validFrom: date, validUntil: expiry, attributedTo: date)
        case .unknown:
            chargeStream = HoldStream.empty
            dischargeStream = HoldStream.empty
        }
        temperatureStream = HoldStream(
            value: observation.temperatureCelsius,
            validFrom: date, validUntil: expiry, attributedTo: date
        )
    }

    /// 跨越窗口边界时收尾当前窗口；中间完全缺失的分钟不生成空窗口。
    private mutating func advanceWindows(through date: Date) {
        if let start = windowStart, date < start.addingTimeInterval(Self.windowLength) { return }
        let targetStart = Self.floorToWindow(date)
        if windowStart != nil {
            finalizeCurrentWindow()
        }
        beginWindow(at: targetStart)
    }

    private mutating func beginWindow(at start: Date) {
        windowStart = start
        systemSeconds = 0
        systemEnergyWh = 0
        systemPeak = 0
        chargeWh = 0
        chargeSeconds = 0
        dischargeWh = 0
        dischargeSeconds = 0
        temperatureSeconds = 0
        temperatureWeightedSum = 0
        temperatureMax = nil
        screenSpan.secondsInWindow = 0
        lowPowerSpan.secondsInWindow = 0
        // 热压力是逐分钟观察到的最大值：每个自然分钟必须重置，
        // 不能把上一分钟的「严重」继承进新窗口；
        // 若当前热状态在新分钟仍持续，该分钟首次 setState/observe 会重新登记。
        thermalOrdinalMax = nil
        thermalLabelForMax = nil
    }

    private mutating func finalizeCurrentWindow() {
        guard let start = windowStart else { return }
        let end = start.addingTimeInterval(Self.windowLength)

        // 未过期样本的尾巴按窗口末端入账，剩余有效期延续到下一窗口
        integrateContinuous(until: end)
        closeDiscreteSpans(at: end)

        let duration = Self.windowLength
        lastCompleted = MinuteAggregate(
            windowStart: start,
            systemEnergyWh: systemSeconds > 0 ? systemEnergyWh : nil,
            systemPowerAverage: systemSeconds > 0 ? systemEnergyWh * 3600 / systemSeconds : nil,
            systemPowerPeak: systemSeconds > 0 ? systemPeak : nil,
            systemCoverage: clamp01(systemSeconds / duration),
            batteryChargeWh: chargeWh,
            batteryChargeSeconds: chargeSeconds,
            batteryDischargeWh: dischargeWh,
            batteryDischargeSeconds: dischargeSeconds,
            temperatureAverage: temperatureSeconds > 0 ? temperatureWeightedSum / temperatureSeconds : nil,
            temperatureMaximum: temperatureMax,
            temperatureCoverage: clamp01(temperatureSeconds / duration),
            screenOnFraction: screenSpan.state == nil ? 0 : clamp01(screenSpan.secondsInWindow / duration),
            lowPowerModeFraction: lowPowerSpan.state == nil ? 0 : clamp01(lowPowerSpan.secondsInWindow / duration),
            maximumThermalStateLabel: thermalLabelForMax,
            maximumThermalStateOrdinal: thermalOrdinalMax
        )
        windowStart = nil
    }

    private mutating func closeDiscreteSpans(at date: Date) {
        // 只有 true 状态才计入份额；false 段只推进跨度起点
        if screenSpan.state == true {
            let lower = max(screenSpan.spanStart, windowStart ?? .distantPast)
            if date > lower { screenSpan.secondsInWindow += date.timeIntervalSince(lower) }
        }
        if screenSpan.state != nil { screenSpan.spanStart = date }
        if lowPowerSpan.state == true {
            let lower = max(lowPowerSpan.spanStart, windowStart ?? .distantPast)
            if date > lower { lowPowerSpan.secondsInWindow += date.timeIntervalSince(lower) }
        }
        if lowPowerSpan.state != nil { lowPowerSpan.spanStart = date }
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
