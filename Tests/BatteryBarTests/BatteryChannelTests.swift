import Foundation
import Testing
@testable import BatteryBar

/// 电池功率方向通道冻结规则反例：
/// 1. 接电+充电+功率可用 → charge；
/// 2. 明确离电+未充电+功率可用 → discharge；
/// 3. 接电未充电 / 矛盾状态（离电却在充电）/ 来源未知 / 功率不可用 → unknown；
/// 4. unknown 不累计任何一侧的 seconds/Wh。
@Suite struct BatteryChannelTests {

    private func makeReading(
        externalConnected: Bool,
        isCharging: Bool,
        batteryPowerAvailable: Bool,
        batteryPower: Double
    ) -> BatteryReader.BatteryReading {
        let info = BatteryInfo(
            designCapacity: 4000, maxCapacity: 3800, cycleCount: 10,
            serialNumber: "serial", manufacturer: "mfg",
            voltage: 11500, instantAmperage: 0, temperature: 30,
            isCharging: isCharging, externalConnected: externalConnected,
            systemPower: 0, batteryPower: batteryPower,
            batteryPowerAvailable: batteryPowerAvailable,
            adapterInputPower: 0,
            systemPowerAvailable: false, systemPowerIsEstimated: false,
            deviceName: "device", chemistry: "Li-ion",
            adapterWatts: 0, adapterProtocol: "未连接"
        )
        return BatteryReader.BatteryReading(
            powerSource: .init(level: 50, isCharging: isCharging, isPluggedIn: externalConnected, timeRemaining: -1, capacity: 50),
            batteryInfo: info,
            provenance: .empty,
            readAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test func pluggedAndChargingGoesToCharge() {
        let reading = makeReading(externalConnected: true, isCharging: true, batteryPowerAvailable: true, batteryPower: 25)
        #expect(reading.batteryChannel == .charge(25))
    }

    @Test func onBatteryAndDischargingGoesToDischarge() {
        let reading = makeReading(externalConnected: false, isCharging: false, batteryPowerAvailable: true, batteryPower: 8)
        #expect(reading.batteryChannel == .discharge(8))
    }

    /// 接电未充电（满电保持/优化充电暂停/80% 上限）即使有功率读数也不进任何一侧
    @Test func pluggedNotChargingIsUnknownEvenWithPower() {
        let reading = makeReading(externalConnected: true, isCharging: false, batteryPowerAvailable: true, batteryPower: 2.1)
        #expect(reading.batteryChannel == .unknown)
    }

    /// 矛盾状态：externalConnected=false 且 isCharging=true → unknown
    @Test func contradictoryStateIsUnknown() {
        let reading = makeReading(externalConnected: false, isCharging: true, batteryPowerAvailable: true, batteryPower: 3)
        #expect(reading.batteryChannel == .unknown)
    }

    /// 功率不可用：兼容哨兵 0 不得被当成有效值进入通道
    @Test func unavailablePowerIsUnknownRegardlessOfState() {
        let charging = makeReading(externalConnected: true, isCharging: true, batteryPowerAvailable: false, batteryPower: 0)
        #expect(charging.batteryChannel == .unknown)
        let discharging = makeReading(externalConnected: false, isCharging: false, batteryPowerAvailable: false, batteryPower: 0)
        #expect(discharging.batteryChannel == .unknown)
    }

    @Test func missingInfoIsUnknown() {
        let reading = makeReading(externalConnected: true, isCharging: true, batteryPowerAvailable: true, batteryPower: 5)
        let withoutInfo = BatteryReader.BatteryReading(
            powerSource: reading.powerSource,
            batteryInfo: nil,
            provenance: .empty,
            readAt: reading.readAt
        )
        #expect(withoutInfo.batteryChannel == .unknown)
    }
}

/// 可信的有效 0W 与「没有读到功率」在质量模型中必须可区分：
/// available + some(0) vs unavailable + nil。
@Suite struct BatteryPowerQualityTests {
    @MainActor
    @Test func samplerDistinguishesTrustedZeroFromSentinel() {
        // 直接验证 PowerSampler 的映射规则所依赖的质量语义：
        let trustedZero = TelemetrySample<Double>.initial(
            .some(0), source: .batteryPowerTelemetry, at: Date(timeIntervalSince1970: 0)
        )
        #expect(trustedZero.availability == .available)
        #expect(trustedZero.value == 0)

        let sentinel = TelemetrySample<Double>.initial(
            .none, source: .unavailable, at: Date(timeIntervalSince1970: 0)
        )
        #expect(sentinel.availability == .unavailable)
        #expect(sentinel.value == nil)
    }
}
