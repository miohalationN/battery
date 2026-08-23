import Foundation
import Testing
@testable import BatteryBar

@Suite struct ChartDownsamplerTests {
    @Test func timeRangeDomainKeepsTheRequestedWallClockSpan() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(TimeRange.hour1.domain(endingAt: end).lowerBound == end.addingTimeInterval(-3600))
        #expect(TimeRange.day6.domain(endingAt: end).lowerBound == end.addingTimeInterval(-21_600))
        #expect(TimeRange.day24.domain(endingAt: end).lowerBound == end.addingTimeInterval(-86_400))
    }

    private func snapshots(count: Int, spikeAt: Int? = nil) -> [BatterySnapshot] {
        var result: [BatterySnapshot] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let timestamp = Date(timeIntervalSince1970: Double(index * 60))
            let level = 100 - Double(index) / 100
            let wattage = index == spikeAt ? 80.0 : 5.0 + Double(index % 7)
            result.append(BatterySnapshot(
                timestamp: timestamp,
                level: level,
                isCharging: false,
                wattage: wattage,
                temperature: 30,
                screenOn: true
            ))
        }
        return result
    }

    @Test func leavesShortSeriesUnchanged() {
        let input = snapshots(count: 30)
        let output = ChartDownsampler.powerSnapshots(input, maxPoints: 240)
        #expect(output.map(\.id) == input.map(\.id))
    }

    @Test func respectsPointLimitAndEndpoints() {
        let input = snapshots(count: 1_440)
        let output = ChartDownsampler.powerSnapshots(input, maxPoints: 240)
        #expect(output.count <= 240)
        #expect(output.first?.id == input.first?.id)
        #expect(output.last?.id == input.last?.id)
        #expect(zip(output, output.dropFirst()).allSatisfy { pair in
            pair.0.timestamp < pair.1.timestamp
        })
    }

    @Test func preservesShortPowerSpike() {
        let input = snapshots(count: 1_440, spikeAt: 731)
        let output = ChartDownsampler.powerSnapshots(input, maxPoints: 240)
        #expect(output.contains { $0.wattage == 80 })
    }
}
