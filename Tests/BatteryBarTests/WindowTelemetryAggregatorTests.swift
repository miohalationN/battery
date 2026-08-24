import Foundation
import Testing
@testable import BatteryBar

/// 分钟聚合器反例（冻结口径）：
/// - 零阶保持积分，单样本最多保持 min(30s, 2×预期间隔)，缺口不外推；
/// - 有效零瓦计入覆盖率，缺失不计入；
/// - 充入/放出能量严格分开；来源未知排除；
/// - 温度按有效时长加权平均；乱序拒绝；睡眠立即截断。
@Suite struct WindowTelemetryAggregatorTests {

    /// 窗口起点对齐 Unix 纪元的整分钟，便于构造观测时间
    private let w0 = Date(timeIntervalSince1970: 1_800_000_000) // 整分钟

    private func aggregate(
        _ aggregator: inout WindowTelemetryAggregator,
        at date: Date,
        load: Double? = nil,
        channel: WindowTelemetryAggregator.BatteryChannel = .unknown,
        temperature: Double? = nil,
        interval: TimeInterval = 15
    ) {
        aggregator.observe(WindowTelemetryAggregator.Observation(
            date: date,
            trustedSystemLoad: load,
            batteryChannel: channel,
            temperatureCelsius: temperature,
            expectedInterval: interval
        ))
    }

    @Test func tenWattsForFullMinuteIsOneSixthWh() throws {
        var agg = WindowTelemetryAggregator()
        let exp15 = 15.0 // hold 30s，链式覆盖整分钟
        aggregate(&agg, at: w0, load: 10, interval: exp15)
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(40), load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(60), load: 10) // 触发窗口收尾

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        #expect(minute.windowStart == w0)
        #expect(abs(minute.systemEnergyWh! - 10.0 * 60.0 / 3600.0) < 1e-9)   // 0.1666667 Wh
        #expect(abs(minute.systemPowerAverage! - 10) < 1e-9)
        #expect(minute.systemPowerPeak == 10)
        #expect(abs(minute.systemCoverage - 1) < 1e-9)
    }

    @Test func thirtySecondsAtTenThenThirtyAtTwentyAveragesFifteen() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(30), load: 20)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        #expect(abs(minute.systemEnergyWh! - 0.25) < 1e-9)
        #expect(abs(minute.systemPowerAverage! - 15) < 1e-9)
        #expect(minute.systemPowerPeak == 20)
    }

    /// 单样本最多保持 30 秒：之后是缺口，严禁外推到窗口末端
    @Test func holdExpiresAfterThirtySecondsNoExtrapolation() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10, interval: 15)          // hold 到 w0+30
        aggregate(&agg, at: w0.addingTimeInterval(90))           // 跨边界触发收尾

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        #expect(abs(minute.systemEnergyWh! - 10.0 * 30.0 / 3600.0) < 1e-9)   // 0.083333 Wh
        #expect(abs(minute.systemCoverage - 0.5) < 1e-9)
        #expect(minute.hasFullSystemMetric == false)
    }

    /// 接电充电功率不得进入系统能耗：无可信系统负载时 systemEnergy 为空，
    /// 充电功率只出现在电池充入侧。
    @Test func chargingPowerNeverEntersSystemEnergy() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: nil, channel: .charge(25))
        aggregate(&agg, at: w0.addingTimeInterval(30), channel: .charge(25))
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        #expect(minute.systemEnergyWh == nil)
        #expect(minute.systemCoverage == 0)
        #expect(minute.batteryDischargeWh == 0)
        #expect(abs(minute.batteryChargeWh - 25.0 * 60.0 / 3600.0) < 1e-9)
    }

    /// 充入/放出严格分开；来源未知两侧都不进
    @Test func chargeAndDischargeStaySeparateUnknownExcluded() throws {
        var chargeOnly = WindowTelemetryAggregator()
        aggregate(&chargeOnly, at: w0, channel: .charge(8))
        aggregate(&chargeOnly, at: w0.addingTimeInterval(60))
        let chargeMinuteopt = chargeOnly.takeCompletedAggregate()
        let chargeMinute = try #require(chargeMinuteopt)
        #expect(chargeMinute.batteryChargeWh > 0 && chargeMinute.batteryDischargeWh == 0)

        var unknown = WindowTelemetryAggregator()
        aggregate(&unknown, at: w0, channel: .unknown)
        aggregate(&unknown, at: w0.addingTimeInterval(60))
        let unknownMinuteopt = unknown.takeCompletedAggregate()
        let unknownMinute = try #require(unknownMinuteopt)
        #expect(unknownMinute.batteryChargeWh == 0)
        #expect(unknownMinute.batteryDischargeWh == 0)

        var dischargeOnly = WindowTelemetryAggregator()
        aggregate(&dischargeOnly, at: w0, channel: .discharge(6))
        aggregate(&dischargeOnly, at: w0.addingTimeInterval(60))
        let dischargeMinuteopt = dischargeOnly.takeCompletedAggregate()
        let dischargeMinute = try #require(dischargeMinuteopt)
        #expect(dischargeMinute.batteryChargeWh == 0 && dischargeMinute.batteryDischargeWh > 0)
    }

    /// 20°C 30 秒 + 40°C 30 秒：加权平均 30°C、最高 40°C（不是样本算术平均之外的口径）
    @Test func temperatureWeightedAverageAndMaximum() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, temperature: 20)
        aggregate(&agg, at: w0.addingTimeInterval(30), temperature: 40)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        #expect(abs(minute.temperatureAverage! - 30) < 1e-9)
        #expect(minute.temperatureMaximum == 40)
        #expect(abs(minute.temperatureCoverage - 1) < 1e-9)
    }

    /// 有效零瓦必须计入覆盖率；缺失不计入
    @Test func validZeroWattCountsTowardCoverageGapDoesNot() throws {
        var zero = WindowTelemetryAggregator()
        aggregate(&zero, at: w0, load: 0)
        aggregate(&zero, at: w0.addingTimeInterval(30), load: 0)
        aggregate(&zero, at: w0.addingTimeInterval(60))
        let zeroMinuteopt = zero.takeCompletedAggregate()
        let zeroMinute = try #require(zeroMinuteopt)
        #expect(zeroMinute.systemEnergyWh == 0)
        #expect(zeroMinute.systemPowerAverage == 0)
        #expect(abs(zeroMinute.systemCoverage - 1) < 1e-9)

        var gap = WindowTelemetryAggregator()
        aggregate(&gap, at: w0, load: nil)
        aggregate(&gap, at: w0.addingTimeInterval(30), load: nil)
        aggregate(&gap, at: w0.addingTimeInterval(60))
        let gapMinuteopt = gap.takeCompletedAggregate()
        let gapMinute = try #require(gapMinuteopt)
        #expect(gapMinute.systemEnergyWh == nil)
        #expect(gapMinute.systemCoverage == 0)
    }

    /// 乱序/负时间整条观测拒绝
    @Test func outOfOrderObservationRejected() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0.addingTimeInterval(50), load: 10)
        // 早于游标的观测必须被忽略，不得产生负时间积分
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 100)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        // 只累计 [+50, +60)：乱序样本被整体丢弃
        #expect(abs(minute.systemEnergyWh! - 10.0 * 10.0 / 3600.0) < 1e-9)
        #expect(minute.systemPowerPeak == 10)
    }

    /// 睡眠开始立即截断连续量：睡前功率不延伸进睡眠区间
    @Test func sleepTruncatesContinuityImmediately() throws {
        var agg = WindowTelemetryAggregator()
        agg.setState(screenOn: true, at: w0)
        aggregate(&agg, at: w0, load: 10)
        agg.setState(screenOn: false, at: w0.addingTimeInterval(25))
        agg.truncateContinuity(at: w0.addingTimeInterval(25))
        agg.setState(screenOn: true, at: w0.addingTimeInterval(90))
        aggregate(&agg, at: w0.addingTimeInterval(95), load: 12)

        let firstWindowopt = agg.takeCompletedAggregate()
        let firstWindow = try #require(firstWindowopt)
        #expect(firstWindow.windowStart == w0)
        // 只累计 [w0, w0+25)：截断后保持链清空
        #expect(abs(firstWindow.systemEnergyWh! - 10.0 * 25.0 / 3600.0) < 1e-9)
        #expect(abs(firstWindow.screenOnFraction - 25.0 / 60.0) < 1e-9)
    }

    /// 前后台节奏切换改变保持上限（5s→10s，15s→30s）
    @Test func foregroundBackgroundSwitchChangesHoldLimit() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10, interval: 5)           // hold 10s
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 10, interval: 15)  // hold 30s
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        // [0,10) + [20,50)：中间 [10,20) 是第一个样本过期缺口
        let expectedSeconds: TimeInterval = 10 + 30
        #expect(abs(minute.systemEnergyWh! - 10.0 * expectedSeconds / 3600.0) < 1e-9)
        #expect(abs(minute.systemCoverage - expectedSeconds / 60.0) < 1e-9)
    }

    /// 低电量模式份额按状态切换精确累计
    @Test func lowPowerModeFractionAccumulatedFromSwitches() throws {
        var agg = WindowTelemetryAggregator()
        agg.setState(lowPowerMode: true, at: w0)
        agg.setState(lowPowerMode: false, at: w0.addingTimeInterval(45))
        agg.setState(lowPowerMode: true, at: w0.addingTimeInterval(55))
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteopt = agg.takeCompletedAggregate()
        let minute = try #require(minuteopt)
        // [0,45) 开 + [45,55) 关 + [55,60) 开 = 50s
        #expect(abs(minute.lowPowerModeFraction - 50.0 / 60.0) < 1e-9)
    }

    /// 完全缺失的分钟不生成空窗口；跨多个边界时只保留最近完成窗口
    @Test func skippedMinutesProduceNoEmptyWindows() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 5)
        // 直接跳到第三分钟：第二分钟从未存在
        aggregate(&agg, at: w0.addingTimeInterval(125), load: 5)
        aggregate(&agg, at: w0.addingTimeInterval(185), load: 5)

        let latestopt = agg.takeCompletedAggregate()
        let latest = try #require(latestopt)
        #expect(latest.windowStart == w0.addingTimeInterval(120))
        // 第二个 take 应为 nil：没有积压队列，内存 O(1)
        let secondTake = agg.takeCompletedAggregate()
        #expect(secondTake == nil)
    }
}
