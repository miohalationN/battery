import Foundation
import Testing
@testable import BatteryBar

@Suite struct SamplingCadenceTests {
    @Test func foregroundUsesSanitizedUserIntervalAndBackgroundDoesNot() {
        #expect(SamplingCadence.effectiveInterval(foregroundInterval: 1, hasVisibleSurface: true) == 1)
        #expect(SamplingCadence.effectiveInterval(foregroundInterval: 30, hasVisibleSurface: true) == 30)
        #expect(SamplingCadence.effectiveInterval(foregroundInterval: 1, hasVisibleSurface: false) == 15)

        #expect(SamplingCadence.sanitizedForegroundInterval(0) == 1)
        #expect(SamplingCadence.sanitizedForegroundInterval(31) == 30)
        #expect(SamplingCadence.sanitizedForegroundInterval(.nan) == 1)
        #expect(SamplingCadence.sanitizedForegroundInterval(.infinity) == 1)
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

    @Test func advancedAndHistoryCadencesRemainIndependent() {
        #expect(SamplingCadence.componentPowerInterval == 10)
        #expect(SamplingCadence.historyInterval == 60)
        #expect(SamplingCadence.componentPowerInterval != SamplingCadence.backgroundInterval)
    }

    @Test func dataStoreNeverPersistsAnUnsafeForegroundInterval() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryBar-SamplingCadence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(directory: directory)

        store.updateRefreshInterval(0)
        #expect(store.currentRefreshInterval() == 1)
        store.updateRefreshInterval(900)
        #expect(store.currentRefreshInterval() == 30)
        store.updateRefreshInterval(.nan)
        #expect(store.currentRefreshInterval() == 1)
    }
}
