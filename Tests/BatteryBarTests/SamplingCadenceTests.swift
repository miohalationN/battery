import Foundation
import Testing
@testable import BatteryBar

@Suite struct SamplingCadenceTests {
    @Test func foregroundIsFixedFiveSecondsAndBackgroundFifteen() {
        // 冻结策略：读数界面可见 5 秒兜底，不可见 15 秒保活；不存在用户可调间隔
        #expect(SamplingCadence.effectiveInterval(hasVisibleSurface: true) == 5)
        #expect(SamplingCadence.effectiveInterval(hasVisibleSurface: false) == 15)
        #expect(SamplingCadence.foregroundInterval == 5)
        #expect(SamplingCadence.backgroundInterval == 15)
    }

    @Test func advancedAndHistoryCadencesRemainIndependent() {
        #expect(SamplingCadence.componentPowerInterval == 10)
        #expect(SamplingCadence.historyInterval == 60)
        #expect(SamplingCadence.componentPowerInterval != SamplingCadence.backgroundInterval)
    }

    @Test func closingOneOfTwoSurfacesKeepsForegroundDemand() {
        var demand = LiveReadingDemand()

        let insertedMain = demand.set(.mainWindow, visible: true)
        let insertedPopover = demand.set(.statusPopover, visible: true)
        #expect(insertedMain)
        #expect(insertedPopover)
        #expect(demand.hasVisibleSurface)

        let removedPopover = demand.set(.statusPopover, visible: false)
        #expect(removedPopover)
        #expect(demand.hasVisibleSurface)

        let removedMain = demand.set(.mainWindow, visible: false)
        #expect(removedMain)
        #expect(!demand.hasVisibleSurface)
    }

    @Test func duplicateLifecycleEventsAreIdempotent() {
        var demand = LiveReadingDemand()

        let firstInsert = demand.set(.mainWindow, visible: true)
        let duplicateInsert = demand.set(.mainWindow, visible: true)
        #expect(firstInsert)
        #expect(!duplicateInsert)
        #expect(demand.hasVisibleSurface)

        let firstRemoval = demand.set(.mainWindow, visible: false)
        let duplicateRemoval = demand.set(.mainWindow, visible: false)
        #expect(firstRemoval)
        #expect(!duplicateRemoval)
        #expect(!demand.hasVisibleSurface)
    }

    @Test func userRefreshIntervalControlIsRemovedFromSource() throws {
        // 反例：仓库不得再提供用户刷新间隔控制，也不得运行时读取旧 interval 文件。
        // 直接扫描数据层源码文本（编译期 API 已删除，此处防止回归）。
        let dataDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/BatteryBarTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/BatteryBar/Data")
        let forbidden = ["currentRefreshInterval", "updateRefreshInterval", "refreshIntervalFile"]
        for file in try FileManager.default.contentsOfDirectory(atPath: dataDir.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOfFile: dataDir.appendingPathComponent(file).path, encoding: .utf8)
            for token in forbidden {
                #expect(!text.contains(token), "\(file) 不得再包含 \(token)")
            }
        }
    }
}

@Suite struct NotificationCoalescerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstEventFiresImmediately() {
        var coalescer = NotificationCoalescer(coalesceWindow: 0.18)
        #expect(coalescer.eventReceived(now: t0) == .fireNow)
        coalescer.fireCompleted(at: t0)
    }

    /// 通知风暴：合并窗口内的重复事件只产生一次延迟触发
    @Test func stormInsideWindowMergesIntoSingleDelayedRead() {
        var coalescer = NotificationCoalescer(coalesceWindow: 0.18)
        #expect(coalescer.eventReceived(now: t0) == .fireNow)
        coalescer.fireCompleted(at: t0)

        // 窗口内的事件：进入延迟
        let second = coalescer.eventReceived(now: t0.addingTimeInterval(0.06))
        guard case .delay(let delay) = second else {
            Issue.record("expected delay, got \(second)")
            return
        }
        #expect(abs(delay - 0.12) < 0.001)

        // 延迟待执行期间的风暴全部并入
        #expect(coalescer.eventReceived(now: t0.addingTimeInterval(0.08)) == .mergeIntoPending)
        #expect(coalescer.eventReceived(now: t0.addingTimeInterval(0.10)) == .mergeIntoPending)

        // 触发完成后重新获得调度资格
        coalescer.fireCompleted(at: t0.addingTimeInterval(0.20))
        #expect(coalescer.eventReceived(now: t0.addingTimeInterval(0.50)) == .fireNow)
    }

    /// 合并窗口外的事件不合并
    @Test func eventOutsideWindowFiresImmediately() {
        var coalescer = NotificationCoalescer(coalesceWindow: 0.18)
        #expect(coalescer.eventReceived(now: t0) == .fireNow)
        coalescer.fireCompleted(at: t0)
        #expect(coalescer.eventReceived(now: t0.addingTimeInterval(1.0)) == .fireNow)
    }

    /// 保持上限口径冻结：min(30 秒, 2×预期间隔)
    @Test func holdLimitFormulaFrozen() {
        #expect(WindowTelemetryAggregator.holdLimit(forExpectedInterval: 5) == 10)
        #expect(WindowTelemetryAggregator.holdLimit(forExpectedInterval: 15) == 30)
        #expect(WindowTelemetryAggregator.holdLimit(forExpectedInterval: 40) == 30)
    }
}
