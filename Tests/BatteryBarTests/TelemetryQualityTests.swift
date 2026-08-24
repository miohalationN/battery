import Foundation
import Testing
@testable import BatteryBar

/// 数据质量语义反例（冻结口径）：
/// - 同值重复读取只变 readAt，changedAt 不变；
/// - 值改变才更新 changedAt；
/// - sourceSampleAt 仅 powermetrics 允许填写，IORegistry 类来源强制 nil；
/// - 合法 0 与 unavailable 必须可区分。
@Suite struct TelemetryQualityTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func repeatedSameValueOnlyAdvancesReadAt() {
        var sample = TelemetrySample<Double>.initial(8.4, source: .telemetrySystemLoad, at: t0)
        #expect(sample.changedAt == t0)

        let t1 = t0.addingTimeInterval(5)
        sample.observe(8.4, source: .telemetrySystemLoad, readAt: t1)
        #expect(sample.readAt == t1)
        #expect(sample.changedAt == t0)          // 同值：changedAt 不变
        #expect(sample.stableFor(asOf: t1.addingTimeInterval(7)) == 12)
    }

    @Test func changedValueUpdatesChangedAt() {
        var sample = TelemetrySample<Double>.initial(8.4, source: .telemetrySystemLoad, at: t0)
        let t1 = t0.addingTimeInterval(10)
        sample.observe(9.1, source: .telemetrySystemLoad, readAt: t1)
        #expect(sample.value == 9.1)
        #expect(sample.changedAt == t1)
    }

    /// available ↔ unavailable 的切换同样是值变化，必须推进 changedAt
    @Test func availabilityTransitionCountsAsChange() {
        var sample = TelemetrySample<Double>.initial(nil, source: .unavailable, at: t0)
        #expect(sample.availability == .unavailable)

        let t1 = t0.addingTimeInterval(3)
        sample.observe(5.0, source: .batteryPowerTelemetry, readAt: t1)
        #expect(sample.availability == .available)
        #expect(sample.changedAt == t1)

        let t2 = t0.addingTimeInterval(6)
        sample.observe(nil, source: .unavailable, readAt: t2)
        #expect(sample.availability == .unavailable)
        #expect(sample.changedAt == t2)
    }

    /// IORegistry 没有硬件时间戳：App 读取时间不得冒充传感器采样时间
    @Test func ioRegistrySourceSampleAtForcedNil() {
        var sample = TelemetrySample<Double>.initial(31.5, source: .smartBatteryTemperature, at: t0, sourceSampleAt: t0)
        #expect(sample.sourceSampleAt == nil)

        sample.observe(
            31.8,
            source: .smartBatteryPackTemperature,
            readAt: t0.addingTimeInterval(5),
            sourceSampleAt: t0.addingTimeInterval(5)
        )
        #expect(sample.sourceSampleAt == nil)
    }

    /// powermetrics 明确提供硬件采样时间：必须如实保留
    @Test func powermetricsKeepsRealSourceSampleTime() {
        let hardwareTime = t0.addingTimeInterval(-2)
        var sample = TelemetrySample<Double>.initial(4.2, source: .powermetrics, isEstimated: true, at: t0, sourceSampleAt: hardwareTime)
        #expect(sample.sourceSampleAt == hardwareTime)

        let nextHardwareTime = t0.addingTimeInterval(8)
        sample.observe(4.4, source: .powermetrics, isEstimated: true, readAt: t0.addingTimeInterval(10), sourceSampleAt: nextHardwareTime)
        #expect(sample.sourceSampleAt == nextHardwareTime)
    }

    /// 零是合法值：`.some(0)` 可用，nil 不可用
    @Test func legalZeroDistinguishableFromUnavailable() {
        var zero = TelemetrySample<Double>.initial(0, source: .batteryPowerTelemetry, at: t0)
        #expect(zero.value == 0)
        #expect(zero.availability == .available)

        zero.observe(nil, source: .unavailable, readAt: t0.addingTimeInterval(5))
        #expect(zero.value == nil)
        #expect(zero.availability == .unavailable)
    }
}
