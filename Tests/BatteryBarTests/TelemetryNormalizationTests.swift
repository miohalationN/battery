import Testing
import Foundation
@testable import BatteryBar

/// IORegistry 遥测功率值归一化：mW/W 单位判定与异常值过滤。
@Suite struct TelemetryNormalizationTests {

    @Test func milliwattsConvertToWatts() {
        // 本机 PowerTelemetryData.SystemLoad 实测 13759（mW）→ 13.759 W
        let watts = BatteryReader.normalizedTelemetryPower(13759)
        #expect(abs(watts - 13.759) < 0.0001)
    }

    @Test func wattValuesKeptAsIs() {
        #expect(BatteryReader.normalizedTelemetryPower(12.5) == 12.5)
        #expect(BatteryReader.normalizedTelemetryPower(0.5) == 0.5)
    }

    @Test func invalidValuesRejected() {
        #expect(BatteryReader.normalizedTelemetryPower(nil) == 0)
        #expect(BatteryReader.normalizedTelemetryPower(-100) == 0)
        #expect(BatteryReader.normalizedTelemetryPower(0) == 0)
        #expect(BatteryReader.normalizedTelemetryPower(Double.nan) == 0)
        #expect(BatteryReader.normalizedTelemetryPower(Double.infinity) == 0)
    }

    @Test func overflowSentinelRejected() {
        // IORegistry 用 UInt64 回绕负数（如 2^64-831）表示"无数据"
        let sentinel = Double(UInt64.max)
        #expect(BatteryReader.normalizedTelemetryPower(sentinel) == 0)
        #expect(BatteryReader.normalizedTelemetryPower(1.8e19) == 0)
    }

    @Test func implausibleDeviceRangeRejected() {
        // 超过合理设备范围的值视为无效，不进入统计
        #expect(BatteryReader.normalizedTelemetryPower(600_000) == 0)   // 600 W
        #expect(BatteryReader.normalizedTelemetryPower(1e9) == 0)
    }

    @Test func signedBatteryPowerUsesAbsoluteMilliwatts() {
        #expect(abs(BatteryReader.normalizedBatteryPower(-5_963) - 5.963) < 0.0001)
        #expect(BatteryReader.normalizedBatteryPower(200) == 0.2)
        #expect(BatteryReader.normalizedBatteryPower(Double.nan) == 0)
        #expect(BatteryReader.normalizedBatteryPower(600_000) == 0)
    }

    @Test func knownTelemetryAlwaysUsesMilliwattsIncludingLowValues() {
        #expect(BatteryReader.normalizedTelemetryMilliwatts(13_759) == 13.759)
        #expect(BatteryReader.normalizedTelemetryMilliwatts(200) == 0.2)
        #expect(BatteryReader.normalizedTelemetryMilliwatts(-1) == 0)
    }

    @Test func packTemperatureUsesCentiDegreesAndRejectsSentinels() {
        // 本机 AppleSmartBatteryPack/BatteryData 实测 4159 → 41.59 °C。
        #expect(abs(BatteryReader.normalizedBatteryTemperature(4_159) - 41.59) < 0.0001)
        #expect(BatteryReader.normalizedBatteryTemperature(31.5) == 31.5)
        #expect(BatteryReader.normalizedBatteryTemperature(65_535) == 0)
        #expect(BatteryReader.normalizedBatteryTemperature(nil) == 0)
    }

    @Test func electricalRangesRejectImplausibleValues() {
        #expect(BatteryReader.normalizedBatteryVoltage(12_796) == 12_796)
        #expect(BatteryReader.normalizedBatteryVoltage(100) == 0)
        #expect(BatteryReader.normalizedBatteryCurrent(-469) == -469)
        #expect(BatteryReader.normalizedBatteryCurrent(1.8e19) == 0)
        #expect(BatteryReader.normalizedCapacity(4_382) == 4_382)
        #expect(BatteryReader.normalizedCapacity(-1) == 0)
        #expect(BatteryReader.normalizedCycleCount(139) == 139)
        #expect(BatteryReader.normalizedCycleCount(100_000) == 0)
    }

    @Test func componentPowerBoundaryRejectsUntrustedHelperValues() {
        #expect(BatteryReader.normalizedComponentPower(0) == 0)
        #expect(BatteryReader.normalizedComponentPower(14.2) == 14.2)
        #expect(BatteryReader.normalizedComponentPower(-1) == 0)
        #expect(BatteryReader.normalizedComponentPower(Double.infinity) == 0)
        #expect(BatteryReader.normalizedComponentPower(500) == 0)
    }
}
