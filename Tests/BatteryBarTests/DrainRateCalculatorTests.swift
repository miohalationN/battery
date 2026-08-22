import Testing
import Foundation
@testable import BatteryBar

/// DrainRateCalculator 纯逻辑测试：快照与时间全部注入，不依赖 DataStore / 系统时钟 / 真实机型。
///
/// 口径不变量：
/// - 历史速率与功率平滑只认 **明确离电**（externalConnected == false）的快照；
/// - 接电未充电（满电保持/优化充电暂停/80% 上限）整体排除；
/// - 来源未知（externalConnected == nil，v1/v2 旧数据/污染点）不参与离电统计；
/// - isOnBattery == false 时直接返回 0（接电不给续航预估）。
@Suite struct DrainRateCalculatorTests {

    /// 基准时间，快照用 minutesAgo 相对它构造
    private let now = Date(timeIntervalSince1970: 1_720_780_800)

    private func snap(_ minutesAgo: Double, level: Double, charging: Bool, watt: Double = 0,
                      ext: Bool? = nil, batteryPower: Double? = nil,
                      estimated: Bool = true, available: Bool? = nil) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            level: level,
            isCharging: charging,
            wattage: watt,
            temperature: 0,
            screenOn: true,
            batteryPower: batteryPower,
            systemPowerAvailable: available,
            systemPowerIsEstimated: estimated,
            externalConnected: ext
        )
    }

    private func makeRate(level: Double = 55, onBattery: Bool = true, power: Double = 10,
                          start: Date? = nil, snaps: [BatterySnapshot]) -> Double {
        DrainRateCalculator.drainRate(
            level: level, isOnBattery: onBattery, batteryPower: power,
            voltage: 11800, maxCapacity: 5000, healthPercent: 90,
            dischargeStart: start, snapshots: snaps, now: now
        )
    }

    // MARK: - chargeRate

    @Test func chargeRateNormalWindow() {
        let snaps = [
            snap(30, level: 40, charging: true, ext: true),
            snap(25, level: 43, charging: true, ext: true),
            snap(20, level: 47, charging: true, ext: true),
            snap(15, level: 51, charging: true, ext: true),
            snap(10, level: 55, charging: true, ext: true),
            snap(5, level: 58, charging: true, ext: true),
            snap(0, level: 60, charging: true, ext: true),
        ]
        let rate = DrainRateCalculator.chargeRate(snapshots: snaps, now: now)
        #expect(abs(rate - 40) < 1.5)
    }

    @Test func chargeRateTooFewSamples() {
        let snaps = [
            snap(10, level: 50, charging: true, ext: true),
            snap(5, level: 52, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateSpanTooShort() {
        let snaps = [
            snap(3, level: 50, charging: true, ext: true),
            snap(2, level: 55, charging: true, ext: true),
            snap(0, level: 60, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateDeltaTooSmall() {
        let snaps = [
            snap(28, level: 50, charging: true, ext: true),
            snap(15, level: 50.2, charging: true, ext: true),
            snap(0, level: 50.5, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateClampedToUpperBound() {
        let snaps = [
            snap(5, level: 20, charging: true, ext: true),
            snap(3, level: 30, charging: true, ext: true),
            snap(0, level: 40, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 80)
    }

    @Test func chargeRateClampedToLowerBound() {
        let snaps = [
            snap(28, level: 50, charging: true, ext: true),
            snap(14, level: 50.5, charging: true, ext: true),
            snap(0, level: 51, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 3)
    }

    @Test func chargeRateIgnoresStaleSnapshots() {
        let snaps = [
            snap(50, level: 40, charging: true, ext: true),
            snap(45, level: 55, charging: true, ext: true),
            snap(40, level: 70, charging: true, ext: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateIgnoresDischargeSnapshots() {
        let snaps = [
            snap(28, level: 50, charging: false, ext: false),
            snap(14, level: 45, charging: false, ext: false),
            snap(0, level: 40, charging: false, ext: false),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    // MARK: - drainRate

    @Test func drainRateInitialPhasePrefersHistory() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 10, ext: false))
        }
        let rate = makeRate(start: now.addingTimeInterval(-60), snaps: snaps)
        #expect(abs(rate - 30) < 1.5)
    }

    @Test func drainRateFusionPhase() {
        // 稳定放电阶段：历史 30%/h × 0.6 + 功率估算 × 0.4
        // 功率估算：10W 恒定，5000mAh × 11.8V = 59Wh → 10 × 100 / 59 ≈ 16.95%/h
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 10, ext: false))
        }
        let rate = makeRate(snaps: snaps)
        let expected = 30.0 * 0.6 + (10.0 * 100.0 / 59.0) * 0.4
        #expect(abs(rate - expected) < 0.5)
    }

    /// 接电（含充电暂停状态）时 drainRate 必须返回 0：不显示续航预估
    @Test func drainRateReturnsZeroWhenNotOnBattery() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 10, ext: false))
        }
        #expect(makeRate(onBattery: false, snaps: snaps) == 0)
    }

    /// 口径不变量：功率估算使用 batteryPower。
    /// 构造 wattage（系统负载）=0 而 batteryPower=10 的离电快照：
    /// 若实现误用 wattage，功率项为 0，结果退化为纯历史速率 30 而非融合值。
    @Test func drainRateUsesBatteryPowerNotSystemLoadField() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5,
                              charging: false, watt: 0, ext: false, batteryPower: 10))
        }
        let rate = makeRate(snaps: snaps)
        let expected = 30.0 * 0.6 + (10.0 * 100.0 / 59.0) * 0.4
        #expect(abs(rate - expected) < 0.5)
    }

    /// 反例：优化充电暂停（接电、未充电、level 平坦、batteryPower≈15）
    /// 持续数小时——这些点不得进入离电时段分段或历史速率；
    /// 随后的真实离电段独立给出速率。
    @Test func pausedChargingPointsExcludedFromHistory() {
        var snaps: [BatterySnapshot] = []
        // 前 4 小时：接电未充电静置（level 80 不动）
        for i in 0..<240 {
            snaps.append(snap(Double(300 - i), level: 80, charging: false, watt: 12, ext: true, batteryPower: 15))
        }
        // 最近 60 分钟：真实离电，90→60（30%/h）
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 9, ext: false))
        }
        let rate = makeRate(snaps: snaps.sorted { $0.timestamp > $1.timestamp })
        // 若暂停段被误当作离电历史，速率会被稀释成远小于 30 的值
        let expected = 30.0 * 0.6 + (9.0 * 100.0 / 59.0) * 0.4
        #expect(abs(rate - expected) < 0.6)
    }

    /// 反例：v1/v2 来源未知的历史污染点（level=100、未充电、估算 0-3W）
    /// 不得进入历史离电速率；明确离电的估算负载仍然可用。
    @Test func unknownSourceEstimatedPollutionExcluded() {
        var snaps: [BatterySnapshot] = []
        // 污染形态：来源未知（ext=nil）、level>=99、未充电、低瓦数估算
        for i in 0..<120 {
            snaps.append(snap(Double(240 - i), level: 100, charging: false,
                              watt: Double(i % 3), ext: nil))
        }
        // 真实离电段：90→60 over 60min（30%/h）
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 9, ext: false))
        }
        let rate = makeRate(snaps: snaps.sorted { $0.timestamp > $1.timestamp })
        let expected = 30.0 * 0.6 + (9.0 * 100.0 / 59.0) * 0.4
        #expect(abs(rate - expected) < 0.6)
    }

    // MARK: - machineBaselineDrainRate

    @Test func baselineUsesBatteryEnergy() {
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 90, maxCapacity: 5000, voltage: 11800, model: "MacBookAir10,1"
        )
        #expect(abs(rate - 600.0 / 59.0) < 0.01)
    }

    @Test func baselineProTakesMoreWatts() {
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 100, maxCapacity: 6000, voltage: 11000, model: "MacBookPro18,3"
        )
        #expect(abs(rate - 900.0 / 66.0) < 0.01)
    }

    @Test func baselineAppleSiliconPlatformKey() {
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 100, maxCapacity: 5000, voltage: 11800, model: "Mac14,2"
        )
        #expect(abs(rate - 800.0 / 59.0) < 0.01)
    }

    @Test func baselineFallbackAppliesHealthFactor() {
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 50, maxCapacity: 0, voltage: 0, model: "MacBookAir10,1"
        )
        #expect(abs(rate - 24.0) < 0.01)
    }
}
