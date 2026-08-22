import Testing
import Foundation
@testable import BatteryBar

/// 离电记录归一化趋势：可比性、门槛过滤、数据不足语义。
@Suite struct OffPowerRecordAnalyzerTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func cycle(daysAgo: Double, start: Double, end: Double, durationH: Double, avgWatt: Double = 7) -> ChargeCycle {
        let startDate = base.addingTimeInterval(-daysAgo * 86_400)
        let endDate = startDate.addingTimeInterval(durationH * 3600)
        let c = ChargeCycle(
            startDate: startDate,
            endDate: endDate,
            startLevel: start,
            endLevel: end,
            totalEnergy: start - end,
            averageWattage: avgWatt
        )
        return c
    }

    @Test func displayableFiltersShortAndFlatCycles() {
        let cycles = [
            cycle(daysAgo: 3, start: 90, end: 89.5, durationH: 0.5),   // 下降 <1% → 剔除
            cycle(daysAgo: 2, start: 90, end: 60, durationH: 0.05),    // 时长 <5min → 剔除
            cycle(daysAgo: 1, start: 80, end: 40, durationH: 4),       // 有效
        ]
        let records = OffPowerRecordAnalyzer.displayableRecords(from: cycles)
        #expect(records.count == 1)
        #expect(records[0].startLevel == 80)
    }

    @Test func normalizedRecordsComparableAcrossDifferentDrops() {
        // 100%→10% 用 5h（18%/h，折算 5.56h）与 50%→30% 用 2h（10%/h，折算 10h）
        // 直接比 duration 不公平；归一化指标应反映真实差异
        let heavy = cycle(daysAgo: 2, start: 100, end: 10, durationH: 5)
        let light = cycle(daysAgo: 1, start: 50, end: 30, durationH: 2)
        let records = OffPowerRecordAnalyzer.normalizedRecords(from: [heavy, light])

        #expect(records.count == 2)
        let byStart = Dictionary(uniqueKeysWithValues: records.map { ($0.cycle.startLevel, $0) })
        let heavyRecord = byStart[100]!
        let lightRecord = byStart[50]!

        #expect(abs(heavyRecord.percentPerHour - 18) < 0.001)
        #expect(abs(heavyRecord.fullChargeHours - 100.0 / 18.0) < 0.001)
        #expect(abs(lightRecord.percentPerHour - 10) < 0.001)
        #expect(abs(lightRecord.fullChargeHours - 10) < 0.001)
        // 轻负载记录的折算满电续航应明显更长，尽管其 duration 更短
        #expect(lightRecord.fullChargeHours > heavyRecord.fullChargeHours)
        #expect(lightRecord.cycle.duration < heavyRecord.cycle.duration)
    }

    @Test func smallDropOrShortDurationExcludedFromTrend() {
        let smallDrop = cycle(daysAgo: 3, start: 80, end: 78, durationH: 3)      // 下降 <5%
        let tooShort = cycle(daysAgo: 2, start: 80, end: 70, durationH: 0.2)     // 12 分钟 <15 分钟
        let valid = cycle(daysAgo: 1, start: 80, end: 60, durationH: 2)
        let records = OffPowerRecordAnalyzer.normalizedRecords(from: [smallDrop, tooShort, valid])
        #expect(records.count == 1)
        #expect(records[0].cycle.id == valid.id)
    }

    @Test func insufficientDataYieldsEmptyNotFakeTrend() {
        let onlySmallDrops = [
            cycle(daysAgo: 2, start: 70, end: 68, durationH: 2),
            cycle(daysAgo: 1, start: 66, end: 64, durationH: 2),
        ]
        #expect(OffPowerRecordAnalyzer.normalizedRecords(from: onlySmallDrops).isEmpty)
        #expect(OffPowerRecordAnalyzer.averageFullChargeHours(of: []) == nil)
    }

    @Test func averageFullChargeHours() {
        let records = OffPowerRecordAnalyzer.normalizedRecords(from: [
            cycle(daysAgo: 2, start: 100, end: 50, durationH: 5),  // 10%/h → 10h
            cycle(daysAgo: 1, start: 90, end: 40, durationH: 5),   // 10%/h → 10h
        ])
        let avg = OffPowerRecordAnalyzer.averageFullChargeHours(of: records)
        #expect(abs(avg! - 10) < 0.001)
    }
}
