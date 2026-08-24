import Foundation
import Testing
@testable import BatteryBar

/// 电池包功率来源选择反例（冻结规则）：
/// 1. 高优先级 raw=0、低优先级正值 → 必须 0（0 立即胜出，不被覆盖）；
/// 2. raw=0、V×I>0 → 必须 0 且非 estimated（V×I 兜底不得覆盖有效 0）；
/// 3. 高优先级坏值、低优先级合法正值 → 取低优先级正值；
/// 4. 全部直接来源缺失、V×I>0 → 乘积回退（estimated）；
/// 5. 全部缺失且乘积 0 → unavailable。
@Suite struct BatteryPowerSelectionTests {

    private let telemetry: TelemetrySource = .batteryPowerTelemetry

    /// 高优先级 raw=0、低优先级正值 → 0 立即胜出
    @Test func zeroAtHighPriorityWinsOverPositiveAtLowPriority() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(0, telemetry), (3200, telemetry)],
            voltage: 0, amperage: 0
        )
        #expect(result.available)
        #expect(result.value == 0)
        #expect(!result.isEstimated)
        #expect(result.source == telemetry)
    }

    /// raw=0、V×I>0 → 必须 0 且非 estimated
    @Test func zeroIsNotOverriddenByVoltageCurrentProduct() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(0, telemetry)],
            voltage: 12_000, amperage: 2_000
        )
        #expect(result.available)
        #expect(result.value == 0)
        #expect(!result.isEstimated)
        #expect(result.source != .voltageCurrentDerived)
    }

    /// 高优先级坏值（越界）、低优先级合法正值 → 取正值
    @Test func badHighPriorityFallsThroughToLegalLowPriority() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(600_000, telemetry), (3_200, telemetry)],
            voltage: 0, amperage: 0
        )
        #expect(result.available)
        #expect(result.value == 3.2)
        #expect(!result.isEstimated)
    }

    /// 全部直接来源缺失、V×I>0 → 乘积回退（estimated）
    @Test func allMissingFallsBackToVoltageCurrentProduct() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(nil, telemetry), (nil, telemetry)],
            voltage: 12_000, amperage: 2_000
        )
        #expect(result.available)
        #expect(abs(result.value - 24) < 1e-9)   // 12000 * 2000 / 1e6
        #expect(result.isEstimated)
        #expect(result.source == .voltageCurrentDerived)
    }

    /// 全部缺失且乘积 0 → unavailable
    @Test func allMissingZeroProductIsUnavailable() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(nil, telemetry), (nil, telemetry)],
            voltage: 0, amperage: 0
        )
        #expect(!result.available)
        #expect(result.value == 0)
        #expect(result.source == .unavailable)
    }

    /// 低优先级坏值也不得覆盖高优先级合法正值（优先级始终高→低）
    @Test func lowPriorityBadValueDoesNotPoisonHighPriorityPositive() {
        let result = BatteryPowerSelection.resolve(
            directCandidates: [(3_200, telemetry), (600_000, telemetry)],
            voltage: 0, amperage: 0
        )
        #expect(result.available)
        #expect(result.value == 3.2)
    }
}
