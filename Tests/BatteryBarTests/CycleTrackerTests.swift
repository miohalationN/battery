import Testing
import Foundation
@testable import BatteryBar

/// CycleTracker 状态机测试：时钟与落盘注入，无需真实等待 5 分钟
@Suite struct CycleTrackerTests {

    private let t0 = Date(timeIntervalSince1970: 1_720_780_800)

    @Test func recordsCycleOnPlugIn() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 启动时插电 → 拔电开始放电周期：100% 起，每 10 分钟掉 2%
        tracker.update(isCharging: true, level: 100, wattage: 20)
        tracker.update(isCharging: false, level: 100, wattage: 5)
        for i in 1...10 {
            current = t0.addingTimeInterval(Double(i) * 600)
            tracker.update(isCharging: false, level: 100 - Double(i) * 2, wattage: 5)
        }
        // 插电结束周期
        current = t0.addingTimeInterval(6000)
        tracker.update(isCharging: true, level: 80, wattage: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        #expect(abs(cycle.startLevel - 100) < 0.01)
        #expect(abs(cycle.endLevel - 80) < 0.01)
        // 放电量按相邻 tick 差值累加：净掉 20%（旧实现会虚增到 110）
        #expect(abs(cycle.totalEnergy - 20) < 0.01)
        // 放电期间 11 次采样全部 5W
        #expect(abs(cycle.averageWattage - 5) < 0.01)
        #expect(cycle.startDate == t0)
        #expect(cycle.endDate == t0.addingTimeInterval(6000))
    }

    @Test func ignoresLevelBounceInEnergy() {
        // 电量读数回跳（98 → 98.5 → 96.5）：只累计正向差值，不累计回跳
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        tracker.update(isCharging: true, level: 100, wattage: 20)
        tracker.update(isCharging: false, level: 98, wattage: 5)
        current = t0.addingTimeInterval(300)
        tracker.update(isCharging: false, level: 98.5, wattage: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isCharging: false, level: 96.5, wattage: 5)
        current = t0.addingTimeInterval(900)
        tracker.update(isCharging: true, level: 96.5, wattage: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        // 正向差值：98→98.5 回跳计 0，98.5→96.5 计 2 → 共 2（净掉 1.5%，回跳不产生负能量）
        #expect(abs(cycle.totalEnergy - 2) < 0.01)
        #expect(abs(cycle.startLevel - 98) < 0.01)
    }

    @Test func filtersShortCycle() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 拔电 2 分钟即插回（时长 < 300s），即使掉了 5% 也不记录
        tracker.update(isCharging: true, level: 100, wattage: 20)
        tracker.update(isCharging: false, level: 100, wattage: 5)
        current = t0.addingTimeInterval(120)
        tracker.update(isCharging: false, level: 95, wattage: 5)
        tracker.update(isCharging: true, level: 95, wattage: 30)

        #expect(saved.isEmpty)
    }

    @Test func filtersTinyDropCycle() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 放电 10 分钟但只掉 0.5%（<1%），视为脏数据不记录
        tracker.update(isCharging: true, level: 100, wattage: 20)
        tracker.update(isCharging: false, level: 100, wattage: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isCharging: false, level: 99.5, wattage: 5)
        tracker.update(isCharging: true, level: 99.5, wattage: 30)

        #expect(saved.isEmpty)
    }

    @Test func startsCycleAtLaunchWhenDischarging() {
        var saved: [ChargeCycle] = []
        var current = t0
        let tracker = CycleTracker(now: { current }, onSave: { saved.append($0) })

        // 启动时就在放电：首个 update 直接以当前电量为 cycle 起点
        tracker.update(isCharging: false, level: 90, wattage: 5)
        current = t0.addingTimeInterval(600)
        tracker.update(isCharging: false, level: 60, wattage: 5)
        tracker.update(isCharging: true, level: 60, wattage: 30)

        #expect(saved.count == 1)
        let cycle = try #require(saved.first)
        #expect(abs(cycle.startLevel - 90) < 0.01)
        #expect(abs(cycle.totalEnergy - 30) < 0.01)
    }
}
