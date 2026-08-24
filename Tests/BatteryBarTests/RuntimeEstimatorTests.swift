import Foundation
import Testing
@testable import BatteryBar

/// 续航/充电估算反例（冻结口径）：
/// - Theil–Sen 中位斜率正确且抗电量回跳/异常点；
/// - 跨度、下降、覆盖不足必须返回数据不足（nil）；
/// - 接电与来源未知样本完全排除；
/// - 满充能量只来自真实容量×合理电压，电压缺失绝不采用 11.1V 默认值；
/// - 两路证据差异 >2 倍时总置信度下降；充电暂停/满电保持不显示估算。
@Suite struct RuntimeEstimatorTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ offsetSeconds: TimeInterval,
        _ level: Double,
        externalConnected: Bool? = false,
        isCharging: Bool = false
    ) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: t0.addingTimeInterval(offsetSeconds),
            level: level,
            isCharging: isCharging,
            wattage: 8,
            temperature: 30,
            screenOn: true,
            batteryPower: 8,
            systemPowerAvailable: true,
            systemPowerIsEstimated: true,
            externalConnected: externalConnected
        )
    }

    /// 线性放电序列：每分钟掉 0.1%（=6%/h）
    private func linearDischarge(minutes: Int, startLevel: Double = 80) -> [BatterySnapshot] {
        (0...minutes).map { minute in
            snapshot(TimeInterval(minute * 60), startLevel - Double(minute) * 0.1)
        }
    }

    // MARK: A. 历史百分比斜率

    /// 20 分钟下降 2%：Theil–Sen 斜率 6%/h 的内部证据成立，
    /// 但 confidence≈0.333 低于展示门槛 0.40 —— dischargeEstimate 必须 nil。
    @Test func twentyMinuteTwoPercentDropYieldsSixPercentPerHour() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 78
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)

        let evidence = try #require(RuntimeEstimator.historicalSlopeEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 6.0) < 0.01)
        #expect(evidence.basis == .historicalSlope)
        #expect(evidence.coverage >= 0.7)
        #expect(evidence.confidence >= 0.3 && evidence.confidence < RuntimeEstimator.minimumDisplayConfidence)

        // 单路出口同样执行门槛：证据存在 ≠ 可展示
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
    }

    /// 单个电量回跳/异常点不能摧毁中位斜率
    @Test func singleLevelSpikeDoesNotDestroyMedianSlope() throws {
        var snaps = linearDischarge(minutes: 20)
        snaps[10] = snapshot(600, 85)                        // 中段回跳 +5%
        snaps.remove(at: 11)

        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 77.9
        input.externalConnected = false
        input.snapshots = snaps

        let evidence = try #require(RuntimeEstimator.historicalSlopeEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 6.0) < 0.35)
    }

    /// 跨度不足 / 净下降不足 / 覆盖不足：一律数据不足
    @Test func insufficientSpanDropOrCoverageReturnNil() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 79
        input.externalConnected = false
        // 跨度只有 15 分钟
        input.snapshots = linearDischarge(minutes: 15)
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)

        // 净下降只有 1.5%
        input.now = t0.addingTimeInterval(1200)
        input.snapshots = (0...20).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * 0.075)
        }
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)

        // 大缺口导致覆盖率 <0.7
        var sparse = (0...10).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * 0.1)
        }
        sparse.append(contentsOf: (0...5).map { minute in
            snapshot(3300 + TimeInterval(minute * 60), 78 - Double(minute) * 0.1)
        })
        input.now = t0.addingTimeInterval(3600)
        input.snapshots = sparse
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)
    }

    /// 接电与来源未知的样本完全排除
    @Test func pluggedAndUnknownSourceSamplesFullyExcluded() throws {
        var snaps = linearDischarge(minutes: 20)
        // 混入接电与来源未知点（其中包含更陡的假斜率）
        snaps[5] = snapshot(300, 79, externalConnected: true, isCharging: true)
        snaps[12] = snapshot(720, 76, externalConnected: nil)

        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 78
        input.externalConnected = false
        input.snapshots = snaps

        let evidence = try #require(RuntimeEstimator.historicalSlopeEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 6.0) < 0.05)
    }

    // MARK: B. 电池功率证据

    private func dischargeAggregates(watts: Double, minutes: Int) -> [MinuteAggregate] {
        (0..<minutes).map { minute in
            MinuteAggregate(
                windowStart: t0.addingTimeInterval(TimeInterval(minute * 60)),
                systemEnergyWh: watts * 60 / 3600,
                systemPowerAverage: watts,
                systemPowerPeak: watts,
                systemCoverage: 1,
                batteryChargeWh: 0,
                batteryChargeSeconds: 0,
                batteryDischargeWh: watts * 60 / 3600,
                batteryDischargeSeconds: 60,
                temperatureAverage: 30,
                temperatureMaximum: 31,
                temperatureCoverage: 1,
                screenOnFraction: 1,
                lowPowerModeFraction: 0,
                maximumThermalStateLabel: "正常",
                maximumThermalStateOrdinal: 0
            )
        }
    }

    /// 5000mAh × 12V = 60Wh，平均 6W 对应 10%/h；50% 约 5 小时
    @Test func sixtyWhPackAtSixWattsIsTenPercentPerHour() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 50
        input.externalConnected = false
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        let evidence = try #require(RuntimeEstimator.batteryPowerEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 10.0) < 0.01)
        #expect(evidence.confidence <= 0.66)                 // 瞬时电压只能中等置信度
        #expect(evidence.band == .medium)

        let estimate = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(abs(estimate.valueHours - 5.0) < 0.01)
    }

    /// 电压缺失时绝不采用 11.1V 默认值——该路径整体不可用
    @Test func missingVoltageNeverFallsBackToDefault() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 50
        input.externalConnected = false
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 0                                  // 未知

        #expect(RuntimeEstimator.batteryPowerEvidence(input) == nil)

        input.voltageMV = 3_000                              // 荒谬电压：拒绝坏数据而非夹值
        #expect(RuntimeEstimator.batteryPowerEvidence(input) == nil)
    }

    // MARK: C. 融合与回退

    /// 两路证据差异 >2 倍且矛盾惩罚后低于门槛（≈0.298 < 0.40）→ 不展示
    @Test func contradictoryEvidenceBelowThresholdReturnsNil() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)       // 斜率路径 6%/h，conf≈0.333
        input.minuteAggregates = dischargeAggregates(watts: 30, minutes: 15)
        input.fullChargeCapacityMah = 5000                   // 功率路径 50%/h（>2×6），conf 0.66
        input.voltageMV = 12_000

        // 两路内部证据都存在
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) != nil)
        #expect(RuntimeEstimator.batteryPowerEvidence(input) != nil)
        // 融合出口：((0.333+0.66)/2)×0.6 < 0.40 → nil
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
    }

    /// 置信度足够高的矛盾双路仍可展示：降置信与扩大区间可观察
    @Test func highConfidenceContradictionStaysObservable() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(3600)
        input.currentLevel = 75
        input.externalConnected = false
        // 60 分钟净下降 5%：斜率 5%/h，confidence=min(1,1,coverage)=1
        input.snapshots = (0...60).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * (5.0 / 60.0))
        }
        // 功率路径 50%/h（>2×5），confidence 0.66
        var longAggregates: [MinuteAggregate] = []
        for minute in 0..<15 {
            longAggregates.append(MinuteAggregate(
                windowStart: t0.addingTimeInterval(TimeInterval(2100 + minute * 60)),
                systemEnergyWh: 0.5,
                systemPowerAverage: 30,
                systemPowerPeak: 32,
                systemCoverage: 1,
                batteryChargeWh: 0,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.5,
                batteryDischargeSeconds: 60,
                temperatureAverage: 30,
                temperatureMaximum: 31,
                temperatureCoverage: 1,
                screenOnFraction: 1,
                lowPowerModeFraction: 0,
                maximumThermalStateLabel: "正常",
                maximumThermalStateOrdinal: 0
            ))
        }
        input.minuteAggregates = longAggregates

        let fused = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(fused.basis == .fused)
        // (1 + 0.66)/2 × 0.6 ≈ 0.498 ≥ 0.40 → 可展示但降置信
        #expect(fused.confidence >= RuntimeEstimator.minimumDisplayConfidence)
        #expect(fused.failureReason?.contains("差异") == true)
        // 矛盾扩大区间
        let spread = (fused.upperHours! - fused.lowerHours!) / fused.valueHours
        #expect(spread > 0.5)
    }

    /// 一致证据的融合置信度高于矛盾场景
    @Test func consistentEvidenceKeepsHigherConfidence() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)       // 6%/h
        // 功率路径也给出 6%/h：60Wh × 10% = 6W
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        let fused = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(fused.basis == .fused)
        #expect(fused.failureReason == nil)
        #expect(fused.band == .medium || fused.band == .high)
    }

    /// App 两路都不可用时返回 nil；系统剩余时间作为独立证据单独提供
    @Test func insufficientAppEvidenceReturnsNilButSystemReportedStaysSeparate() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(600)
        input.currentLevel = 50
        input.externalConnected = false
        input.snapshots = []
        input.minuteAggregates = []
        input.systemReportedMinutes = 300

        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        let system = RuntimeEstimator.systemReportedEstimate(input)
        #expect(system != nil)
        #expect(system?.basis == .systemReported)
        // 系统证据永不与 App 证据融合：basis 恒为 systemReported
    }

    /// 明确接电或来源未知时不显示离电续航
    @Test func noOffPowerEstimateWhenPluggedOrUnknown() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.snapshots = linearDischarge(minutes: 20)
        input.externalConnected = true
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)

        input.externalConnected = nil                        // 来源未知
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        #expect(RuntimeEstimator.systemReportedEstimate(input) == nil)
    }

    // MARK: 充电估算

    /// 正常充电：30 分钟 +3%，中位斜率 6%/h，剩余时间标注按当前速度
    @Test func normalChargingProducesTimeToFull() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 50
        input.isCharging = true
        input.externalConnected = true
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * 0.1,
                     externalConnected: true, isCharging: true)
        }

        let estimate = try #require(RuntimeEstimator.chargeEstimate(input))
        #expect(abs(estimate.ratePercentPerHour - 6.0) < 0.01)
        #expect(abs(estimate.valueHours - 50.0 / 6.0) < 0.1)
        #expect(estimate.band != .high || estimate.confidence <= 1)
    }

    /// 充电暂停（isCharging=false）、满电保持、80% 上限无正增长：不显示时间
    @Test func pausedOrHeldChargingShowsNoEstimate() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 80
        input.isCharging = false                             // 接电暂停/满电保持/上限
        input.externalConnected = true
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 80, externalConnected: true, isCharging: false)
        }
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)

        // 在充电但无正增长（满电保持抖动）
        input.isCharging = true
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 80 + [0, 0.2, -0.1][minute % 3],
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
    }

    /// 80% 以上涓流阶段置信度 ×0.6 后低于门槛（0.54→0.324）→ 不展示；
    /// 5 分钟仅增长 1% 的低置信充电证据（≈0.15）同样不展示；
    /// 200%/h 异常速率直接拒绝而不是夹值。
    @Test func tricklePhaseLowersConfidenceAndAbsurdRateRejected() throws {
        func chargingInput(level: Double) -> RuntimeEstimator.Inputs {
            var input = RuntimeEstimator.Inputs()
            input.now = t0.addingTimeInterval(1800)
            input.currentLevel = level
            input.isCharging = true
            input.externalConnected = true
            input.snapshots = (0...30).map { minute in
                snapshot(TimeInterval(minute * 60), level + Double(minute) * 0.1,
                         externalConnected: true, isCharging: true)
            }
            return input
        }

        // 正常速率（30 分钟 +3%，conf≈0.54 ≥ 0.40）可展示
        let normal = try #require(RuntimeEstimator.chargeEstimate(chargingInput(level: 50)))
        #expect(normal.confidence >= RuntimeEstimator.minimumDisplayConfidence)

        // 涓流阶段（level>85）：0.54×0.6 < 0.40 → nil
        #expect(RuntimeEstimator.chargeEstimate(chargingInput(level: 85)) == nil)

        // 低置信短窗口：5 分钟 +1%（斜率 12%/h 合法，但 conf≈0.15）
        var short = RuntimeEstimator.Inputs()
        short.now = t0.addingTimeInterval(300)
        short.currentLevel = 50
        short.isCharging = true
        short.externalConnected = true
        short.snapshots = (0...5).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * 0.2,
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(short) == nil)

        // 200%/h 的异常斜率直接拒绝（不再夹到 80）
        var absurd = chargingInput(level: 50)
        absurd.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * (200.0 / 60.0),
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(absurd) == nil)
    }
}
