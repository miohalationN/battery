import Testing
import Foundation
@testable import BatteryBar

/// CycleTracker 状态机测试：时钟与落盘注入，无需真实等待 5 分钟。
/// 状态机只认插拔状态（isPluggedIn）——满电保持/优化充电暂停/80% 上限
/// 都是接电未充电，不得误记为离电使用。
@Suite struct CycleTrackerTests {

    private let t0 = Date(timeIntervalSince1970: 1_720_780_800)

    @Test func recordsCycleOnPlugIn() throws {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 启动时接电 → 拔电开始离电时段：100% 起，每 10 分钟掉 2%
        tracker.update(isPluggedIn: true, level: 100, batteryPower: 20)
        tracker.update(isPluggedIn: false, level: 100, batteryPower: 5)
        for i in 1...10 {
            current = t0.addingTimeInterval(Double(i) * 600)
            tracker.update(isPluggedIn: false, level: 100 - Double(i) * 2, batteryPower: 5)
        }
        // 接电结束时段
        current = t0.addingTimeInterval(6000)
        tracker.update(isPluggedIn: true, level: 80, batteryPower: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        #expect(abs(cycle.startLevel - 100) < 0.01)
        #expect(abs(cycle.endLevel - 80) < 0.01)
        #expect(abs(cycle.totalEnergy - 20) < 0.01)
        #expect(abs(cycle.averageWattage - 5) < 0.01)
        #expect(cycle.startDate == t0)
        #expect(cycle.endDate == t0.addingTimeInterval(6000))
    }

    /// 反例：优化充电暂停 / 满电保持（externalConnected=true、isCharging=false）
    /// 持续数小时，不产生任何离电记录。
    @Test func pausedChargingOnPowerProducesNoRecord() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 接电、未充电、level=100，持续 6 小时（60s 一条 × 360）
        tracker.update(isPluggedIn: true, level: 100, batteryPower: 25)
        for i in 1...360 {
            current = t0.addingTimeInterval(Double(i) * 60)
            tracker.update(isPluggedIn: true, level: 100, batteryPower: 0.2)
        }
        #expect(saved.isEmpty)

        // 中途 isCharging 抖动也不影响：状态机根本不看充电标志
        current = t0.addingTimeInterval(21600 + 600)
        tracker.update(isPluggedIn: true, level: 99.8, batteryPower: 4.0)
        #expect(saved.isEmpty)
    }

    /// 反例：80% 上限（externalConnected=true、isCharging=false、level=80）
    /// 长时间静置同样不产生离电记录；随后真正拔电才按插拔状态开始记录。
    @Test func eightyPercentLimitThenRealUnplug() throws {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 3 小时 80% 上限静置
        tracker.update(isPluggedIn: true, level: 80, batteryPower: 15)
        for i in 1...180 {
            current = t0.addingTimeInterval(Double(i) * 60)
            tracker.update(isPluggedIn: true, level: 80, batteryPower: 0)
        }
        #expect(saved.isEmpty)

        // 真正拔电：开始离电时段
        current = t0.addingTimeInterval(12000)
        tracker.update(isPluggedIn: false, level: 80, batteryPower: 7)
        current = t0.addingTimeInterval(12000 + 3600)
        tracker.update(isPluggedIn: false, level: 74, batteryPower: 7)
        current = t0.addingTimeInterval(12000 + 3700)
        tracker.update(isPluggedIn: true, level: 73.9, batteryPower: 28)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        // 时段从"拔电点"起算，而不是把之前的接电静置算进去
        #expect(cycle.startDate == t0.addingTimeInterval(12000))
        #expect(abs(cycle.startLevel - 80) < 0.01)
    }

    @Test func ignoresLevelBounceInEnergy() throws {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        tracker.update(isPluggedIn: true, level: 100, batteryPower: 20)
        tracker.update(isPluggedIn: false, level: 98, batteryPower: 5)
        current = t0.addingTimeInterval(300)
        tracker.update(isPluggedIn: false, level: 98.5, batteryPower: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isPluggedIn: false, level: 96.5, batteryPower: 5)
        current = t0.addingTimeInterval(900)
        tracker.update(isPluggedIn: true, level: 96.5, batteryPower: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        #expect(abs(cycle.totalEnergy - 2) < 0.01)
        #expect(abs(cycle.startLevel - 98) < 0.01)
    }

    @Test func filtersShortCycle() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        tracker.update(isPluggedIn: true, level: 100, batteryPower: 20)
        tracker.update(isPluggedIn: false, level: 100, batteryPower: 5)
        current = t0.addingTimeInterval(120)
        tracker.update(isPluggedIn: false, level: 95, batteryPower: 5)
        tracker.update(isPluggedIn: true, level: 95, batteryPower: 30)

        #expect(saved.isEmpty)
    }

    @Test func filtersTinyDropCycle() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        tracker.update(isPluggedIn: true, level: 100, batteryPower: 20)
        tracker.update(isPluggedIn: false, level: 100, batteryPower: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isPluggedIn: false, level: 99.5, batteryPower: 5)
        tracker.update(isPluggedIn: true, level: 99.5, batteryPower: 30)

        #expect(saved.isEmpty)
    }

    @Test func startsCycleAtLaunchWhenDischarging() throws {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        tracker.update(isPluggedIn: false, level: 90, batteryPower: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isPluggedIn: false, level: 60, batteryPower: 5)
        tracker.update(isPluggedIn: true, level: 60, batteryPower: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        #expect(abs(cycle.startLevel - 90) < 0.01)
        #expect(abs(cycle.totalEnergy - 30) < 0.01)
    }
}
