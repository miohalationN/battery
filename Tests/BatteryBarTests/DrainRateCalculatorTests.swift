import Testing
import Foundation
@testable import BatteryBar

/// DrainRateCalculator 纯逻辑测试：快照与时间全部注入，不依赖 DataStore / 系统时钟 / 真实机型
@Suite struct DrainRateCalculatorTests {

    /// 基准时间，快照用 minutesAgo 相对它构造
    private let now = Date(timeIntervalSince1970: 1_720_780_800)

    private func snap(_ minutesAgo: Double, level: Double, charging: Bool, watt: Double = 0) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            level: level,
            isCharging: charging,
            wattage: watt,
            temperature: 0,
            screenOn: true
        )
    }

    // MARK: - chargeRate

    @Test func chargeRateNormalWindow() {
        // 30 分钟从 40% 充到 60% → 40%/h
        let snaps = [
            snap(30, level: 40, charging: true),
            snap(25, level: 43, charging: true),
            snap(20, level: 47, charging: true),
            snap(15, level: 51, charging: true),
            snap(10, level: 55, charging: true),
            snap(5, level: 58, charging: true),
            snap(0, level: 60, charging: true),
        ]
        let rate = DrainRateCalculator.chargeRate(snapshots: snaps, now: now)
        #expect(abs(rate - 40) < 1.5)
    }

    @Test func chargeRateTooFewSamples() {
        let snaps = [
            snap(10, level: 50, charging: true),
            snap(5, level: 52, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateSpanTooShort() {
        // 跨度不足 4 分钟：样本噪声太大，不给出速率
        let snaps = [
            snap(3, level: 50, charging: true),
            snap(2, level: 55, charging: true),
            snap(0, level: 60, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateDeltaTooSmall() {
        // 30 分钟只涨 0.5%：变化不足 1%，不给出速率
        let snaps = [
            snap(28, level: 50, charging: true),
            snap(15, level: 50.2, charging: true),
            snap(0, level: 50.5, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateClampedToUpperBound() {
        // 5 分钟涨 20%（原始 240%/h）→ 限幅 80
        let snaps = [
            snap(5, level: 20, charging: true),
            snap(3, level: 30, charging: true),
            snap(0, level: 40, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 80)
    }

    @Test func chargeRateClampedToLowerBound() {
        // 30 分钟涨 1%（原始 2%/h）→ 抬到下限 3
        let snaps = [
            snap(28, level: 50, charging: true),
            snap(14, level: 50.5, charging: true),
            snap(0, level: 51, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 3)
    }

    @Test func chargeRateIgnoresStaleSnapshots() {
        // 充电样本都在 30 分钟窗口之外 → 无有效样本
        let snaps = [
            snap(50, level: 40, charging: true),
            snap(45, level: 55, charging: true),
            snap(40, level: 70, charging: true),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    @Test func chargeRateIgnoresDischargeSnapshots() {
        // 只有放电样本：不参与充电速率
        let snaps = [
            snap(28, level: 50, charging: false),
            snap(14, level: 45, charging: false),
            snap(0, level: 40, charging: false),
        ]
        #expect(DrainRateCalculator.chargeRate(snapshots: snaps, now: now) == 0)
    }

    // MARK: - drainRate

    @Test func drainRateInitialPhasePrefersHistory() {
        // 拔电 60s（初期），有历史放电段（90→60，60 分钟 → 30%/h）→ 直接用历史速率
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 10))
        }
        let rate = DrainRateCalculator.drainRate(
            level: 55, isCharging: false, wattage: 10, voltage: 11800,
            maxCapacity: 5000, healthPercent: 90,
            dischargeStart: now.addingTimeInterval(-60),
            snapshots: snaps, now: now
        )
        #expect(abs(rate - 30) < 1.5)
    }

    @Test func drainRateFusionPhase() {
        // 稳定放电阶段：历史 30%/h × 0.6 + 功率估算 × 0.4
        // 功率估算：10W 恒定，5000mAh × 11.8V = 59Wh → 10 × 100 / 59 ≈ 16.95%/h
        var snaps: [BatterySnapshot] = []
        for i in 0..<7 {
            snaps.append(snap(Double(60 - i * 10), level: 90 - Double(i) * 5, charging: false, watt: 10))
        }
        let rate = DrainRateCalculator.drainRate(
            level: 55, isCharging: false, wattage: 10, voltage: 11800,
            maxCapacity: 5000, healthPercent: 90,
            dischargeStart: nil,
            snapshots: snaps, now: now
        )
        let expected = 30.0 * 0.6 + (10.0 * 100.0 / 59.0) * 0.4
        #expect(abs(rate - expected) < 0.5)
    }

    // MARK: - machineBaselineDrainRate

    @Test func baselineUsesBatteryEnergy() {
        // MacBook Air 典型 6W / 5000mAh × 11.8V = 59Wh → 600/59 ≈ 10.17%/h
        // （满充容量已反映健康度，容量路径不再叠加健康度因子）
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 90, maxCapacity: 5000, voltage: 11800, model: "MacBookAir10,1"
        )
        #expect(abs(rate - 600.0 / 59.0) < 0.01)
    }

    @Test func baselineProTakesMoreWatts() {
        // Pro 9W / 6000mAh × 11.0V = 66Wh → 900/66 ≈ 13.64%/h
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 100, maxCapacity: 6000, voltage: 11000, model: "MacBookPro18,3"
        )
        #expect(abs(rate - 900.0 / 66.0) < 0.01)
    }

    @Test func baselineAppleSiliconPlatformKey() {
        // Apple Silicon hw.model 是 "Mac14,2" 平台键（不含 macbook 字样），走默认 8W
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 100, maxCapacity: 5000, voltage: 11800, model: "Mac14,2"
        )
        #expect(abs(rate - 800.0 / 59.0) < 0.01)
    }

    @Test func baselineFallbackAppliesHealthFactor() {
        // 容量未知：Air 兜底 12%/h；健康度 50% → 因子 100/50 = 2 → 24%/h
        let rate = DrainRateCalculator.machineBaselineDrainRate(
            healthPercent: 50, maxCapacity: 0, voltage: 0, model: "MacBookAir10,1"
        )
        #expect(abs(rate - 24.0) < 0.01)
    }
}
