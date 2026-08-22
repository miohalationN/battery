import Testing
import Foundation
@testable import BatteryBar

/// BatterySnapshot v1/v2/v3 兼容、电源来源 provenance 与功率口径测试。
///
/// 关键不变量：
/// - isCharging 只表达电池包是否充入；externalConnected 缺失 = 来源未知，
///   不得用 !isCharging 推断离电；
/// - 估算负载只在明确离电（externalConnected == false）时可信；
///   实测遥测（estimated == false）独立可信；
/// - "接电未充电被误标为可用离电负载"的污染点（level>=99、!charging、
///   estimated=true、无 externalConnected）必须被 trustedSystemLoad 排除。
@Suite struct SnapshotCompatTests {

    private let base = Date(timeIntervalSince1970: 1_720_780_800)

    // MARK: - v1 JSON 解码（属性名键；无新字段 → 来源未知）

    @Test func v1ChargingSnapshotExcludedFromSystemLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":80,"isCharging":true,
         "wattage":28.5,"temperature":31.0,"screenOn":true,"cpuPower":0,"gpuPower":0}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.isCharging)
        #expect(snap.systemPowerAvailable == false)      // 充电功率不能冒充系统负载
        #expect(snap.trustedSystemLoad == nil)
        #expect(snap.externalConnected == nil)           // v1 无电源字段，未知
        #expect(snap.isDefinitelyOnBattery == false)
        #expect(snap.batteryPower == 28.5)
    }

    @Test func v1DischargingSnapshotUnknownSourceExcluded() throws {
        // 旧离电点：曾经可作为估算负载；现在因来源未知而保守排除
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":60,"isCharging":false,
         "wattage":8.4,"temperature":30.0,"screenOn":true}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.systemPowerAvailable == true)
        #expect(snap.systemPowerIsEstimated == true)
        #expect(snap.externalConnected == nil)
        #expect(snap.trustedSystemLoad == nil)           // 来源未知 + 估算 → 排除
    }

    // MARK: - 核心反例：接电未充电（满电/优化充电暂停/80% 上限）

    /// externalConnected=true、isCharging=false、level=100 的旧格式污染点：
    /// 不得作为可用系统负载参与统计，也不得视为离电。
    @Test func legacyPluggedNotChargingPollutionRejected() throws {
        // v2 本地 journal 形态：有估算标记，无 externalConnected 键
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":100,"isCharging":false,
         "wattage":2.1,"batteryPower":2.1,"systemPowerAvailable":true,"systemPowerIsEstimated":true,
         "temperature":31.0,"screenOn":true}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.systemPowerAvailable == true)       // 旧规则标了"可用"
        #expect(snap.trustedSystemLoad == nil)           // 但来源未知 + 估算 → 排除
        #expect(snap.isDefinitelyOnBattery == false)     // 不是明确离电
    }

    /// 同形态的新格式数据（externalConnected 显式 true）同样排除；
    /// 真正离电（显式 false）的估算负载仍然可用。
    @Test func explicitExternalConnectedDrivesTrust() {
        let paused = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                     wattage: 2.0, temperature: 0, screenOn: true,
                                     systemPowerAvailable: true, systemPowerIsEstimated: true,
                                     externalConnected: true)
        #expect(paused.trustedSystemLoad == nil)
        #expect(!paused.isDefinitelyOnBattery)

        let onBattery = BatterySnapshot(timestamp: base, level: 70, isCharging: false,
                                        wattage: 8.5, temperature: 0, screenOn: true,
                                        batteryPower: 8.5, systemPowerAvailable: true,
                                        systemPowerIsEstimated: true, externalConnected: false)
        #expect(onBattery.trustedSystemLoad == 8.5)
        #expect(onBattery.isDefinitelyOnBattery)

        // 实测遥测独立可信：即使电源状态是接电未充电也保留
        let telemetryPaused = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                              wattage: 12.3, temperature: 0, screenOn: true,
                                              systemPowerAvailable: true, systemPowerIsEstimated: false,
                                              externalConnected: true)
        #expect(telemetryPaused.trustedSystemLoad == 12.3)

        // 遥测但来源字段缺失（v2 实测点）：按其独立可信标记保留
        let telemetryUnknownSource = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                                     wattage: 11.8, temperature: 0, screenOn: true,
                                                     systemPowerAvailable: true, systemPowerIsEstimated: false,
                                                     externalConnected: nil)
        #expect(telemetryUnknownSource.trustedSystemLoad == 11.8)
    }

    // MARK: - v2/v3 编解码往返

    @Test func v2CodableRoundTrip() throws {
        var snap = BatterySnapshot(
            timestamp: base,
            level: 42,
            isCharging: false,
            wattage: 9.1,
            temperature: 27.5,
            screenOn: true,
            batteryPower: 9.3,
            systemPowerAvailable: true,
            systemPowerIsEstimated: false
        )
        snap.dirty = false
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
        #expect(decoded.externalConnected == nil)        // 未设置 → 键缺失 → 解回 nil
    }

    @Test func v3CodableRoundTripKeepsExternalConnected() throws {
        for ext in [true, false] {
            let snap = BatterySnapshot(timestamp: base, level: 55, isCharging: false,
                                       wattage: 10, temperature: 29, screenOn: true,
                                       externalConnected: ext)
            let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
            #expect(decoded.externalConnected == ext)
            #expect(decoded == snap)
        }
    }

    @Test func memberwiseDefaultsDeriveFromChargingState() {
        let charging = BatterySnapshot(timestamp: base, level: 90, isCharging: true, wattage: 30, temperature: 0, screenOn: true)
        #expect(charging.systemPowerAvailable == false)
        #expect(charging.batteryPower == 30)
        #expect(charging.externalConnected == nil)

        let discharging = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 6, temperature: 0, screenOn: true)
        #expect(discharging.systemPowerAvailable == true)
        #expect(discharging.systemPowerIsEstimated == true)

        let explicit = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 13.8, temperature: 0, screenOn: true,
                                       batteryPower: 0.2, systemPowerAvailable: true, systemPowerIsEstimated: false,
                                       externalConnected: true)
        #expect(explicit.batteryPower == 0.2)
        #expect(explicit.systemPowerIsEstimated == false)
        #expect(explicit.trustedSystemLoad == 13.8)      // 遥测不受电源状态影响
    }

    // MARK: - WebDAV JSONL

    @Test func remoteJSONRoundTripPreservesNewFields() throws {
        let snap = BatterySnapshot(
            timestamp: base, level: 55, isCharging: true, wattage: 14.2,
            temperature: 29, screenOn: false,
            batteryPower: 22.4, systemPowerAvailable: true, systemPowerIsEstimated: false,
            externalConnected: true
        )
        let dict = snap.toJSON()
        #expect(dict["ext"] as? Bool == true)
        let parsed = try #require(BatterySnapshot.from(remoteJSON: dict))
        #expect(parsed.id == snap.id)
        #expect(parsed.wattage == 14.2)
        #expect(parsed.batteryPower == 22.4)
        #expect(parsed.systemPowerAvailable == true)
        #expect(parsed.systemPowerIsEstimated == false)
        #expect(parsed.externalConnected == true)
        #expect(parsed.dirty == false)
    }

    @Test func remoteJSONLegacyFieldsDeriveSemanticsConservatively() throws {
        // 远端旧格式：只有 watt，无任何新字段 → 与本地 v1 规则一致且保守
        let dict: [String: Any] = [
            "id": UUID().uuidString,
            "ts": 1_720_780_800.0,
            "level": 100.0,
            "charging": false,
            "watt": 25.0,
            "temp": 31.0,
            "screen": true,
        ]
        let parsed = try #require(BatterySnapshot.from(remoteJSON: dict))
        #expect(!parsed.isCharging)
        #expect(parsed.systemPowerAvailable == false)
        #expect(parsed.batteryPower == 25.0)
        #expect(parsed.externalConnected == nil)
        #expect(parsed.trustedSystemLoad == nil)
        #expect(parsed.dirty == false)

        // 远端带估算标记但无 ext：同样保守排除
        var polluted = dict
        polluted["powerAvailable"] = true
        polluted["powerEstimated"] = true
        polluted["watt"] = 2.0
        let p2 = try #require(BatterySnapshot.from(remoteJSON: polluted))
        #expect(p2.trustedSystemLoad == nil)
    }

    @Test func remoteJSONRejectsMalformedLines() {
        #expect(BatterySnapshot.from(remoteJSON: [:]) == nil)
        #expect(BatterySnapshot.from(remoteJSON: ["id": "not-a-uuid", "ts": 1.0]) == nil)
        #expect(BatterySnapshot.from(remoteJSON: ["ts": 1.0]) == nil)
    }

    @Test func toJSONContainsNewKeys() {
        let snap = BatterySnapshot(timestamp: base, level: 10, isCharging: false, wattage: 2,
                                   temperature: 30, screenOn: false, externalConnected: false)
        let keys = Set(snap.toJSON().keys)
        #expect(keys.isSuperset(of: ["id", "ts", "level", "charging", "watt", "batteryWatt",
                                     "powerAvailable", "powerEstimated", "temp", "screen",
                                     "cpu", "gpu", "disp", "dram", "ext"]))
    }
}

/// 快照保留窗口：24 小时裁剪、未来异常点拒绝、硬上限。
@Suite struct RetentionPolicyTests {

    private func makeSnaps(_ agesHours: [Double], now: Date) -> [BatterySnapshot] {
        agesHours.map { BatterySnapshot(timestamp: now.addingTimeInterval($0 * 3600), level: 50, isCharging: false, wattage: 5, temperature: 0, screenOn: true) }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func olderThan24hDropped() {
        let snaps = makeSnaps([-30, -25, -10, -1], now: now)
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.count == 2)
        #expect(retained.allSatisfy { $0.timestamp >= now.addingTimeInterval(-24 * 3600) })
    }

    @Test func futureOutliersRejected() {
        var snaps = makeSnaps([-2, -1], now: now)
        snaps.append(BatterySnapshot(timestamp: now.addingTimeInterval(3600), level: 50, isCharging: false, wattage: 5, temperature: 0, screenOn: true))
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.count == 2)
    }

    @Test func smallClockSkewTolerated() {
        let skewed = [BatterySnapshot(timestamp: now.addingTimeInterval(120), level: 50, isCharging: false, wattage: 5, temperature: 0, screenOn: true)]
        #expect(DataStore.retainedSnapshots(skewed, now: now).count == 1)
    }

    @Test func hardCapTrimsOldest() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<2000 {
            snaps.append(BatterySnapshot(
                timestamp: now.addingTimeInterval(TimeInterval(-i)),
                level: 50, isCharging: false, wattage: 5, temperature: 0, screenOn: true
            ))
        }
        let retained = DataStore.retainedSnapshots(snaps, now: now, hours: 24, maxCount: 1500)
        #expect(retained.count == 1500)
        #expect(!retained.contains { $0.id == snaps.last!.id })
        #expect(retained.contains { $0.id == snaps[0].id })
    }

    @Test func outputSortedByTimestamp() {
        let snaps = Array(makeSnaps([-3, -1, -2], now: now).shuffled())
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.map(\.timestamp) == retained.map(\.timestamp).sorted())
    }
}
