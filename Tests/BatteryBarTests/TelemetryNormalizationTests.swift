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
}
