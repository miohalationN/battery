import Testing
import Foundation
@testable import BatteryBar

/// BatterySnapshot v1/v2 兼容与功率口径测试。
///
/// 关键不变量：
/// - 旧 charging 快照 systemPowerAvailable=false，只作电池功率，不进入系统负载统计；
/// - 旧 discharging 快照可作为估算系统负载（available=true, estimated=true）；
/// - 新字段在 Codable / toJSON / from(remoteJSON:) 三条路径上往返一致。
@Suite struct SnapshotCompatTests {

    private let base = Date(timeIntervalSince1970: 1_720_780_800)

    // MARK: - v1 JSON 解码（无新字段；v1 snapshots.json 使用属性名键）

    @Test func v1ChargingSnapshotExcludedFromSystemLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":80,"isCharging":true,
         "wattage":28.5,"temperature":31.0,"screenOn":true,"cpuPower":0,"gpuPower":0}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.isCharging)
        #expect(snap.systemPowerAvailable == false)   // 充电功率不能冒充系统负载
        #expect(snap.systemLoad == nil)
        #expect(snap.batteryPower == 28.5)            // 但仍是有效的电池功率
    }

    @Test func v1DischargingSnapshotUsableAsEstimatedLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":60,"isCharging":false,
         "wattage":8.4,"temperature":30.0,"screenOn":true}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.systemPowerAvailable == true)
        #expect(snap.systemPowerIsEstimated == true)
        #expect(snap.systemLoad == 8.4)
    }

    // MARK: - v2 编解码往返

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
            systemPowerIsEstimated: false,
            cpuPower: 2.2, gpuPower: 0.8, displayPower: 1.7, dramPower: 0.3
        )
        snap.dirty = false
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
        #expect(decoded.dirty == false)
    }

    /// 未显式给出口径的构造按 isCharging 推导，防止旧调用点把充电功率当系统负载
    @Test func memberwiseDefaultsDeriveFromChargingState() {
        let charging = BatterySnapshot(timestamp: base, level: 90, isCharging: true, wattage: 30, temperature: 0, screenOn: true)
        #expect(charging.systemPowerAvailable == false)
        #expect(charging.batteryPower == 30)

        let discharging = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 6, temperature: 0, screenOn: true)
        #expect(discharging.systemPowerAvailable == true)
        #expect(discharging.systemPowerIsEstimated == true)

        let explicit = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 13.8, temperature: 0, screenOn: true,
                                       batteryPower: 0.2, systemPowerAvailable: true, systemPowerIsEstimated: false)
        #expect(explicit.batteryPower == 0.2)
        #expect(explicit.systemPowerIsEstimated == false)
    }

    // MARK: - WebDAV JSONL

    @Test func remoteJSONRoundTripPreservesNewFields() throws {
        let snap = BatterySnapshot(
            timestamp: base, level: 55, isCharging: true, wattage: 14.2,
            temperature: 29, screenOn: false,
            batteryPower: 22.4, systemPowerAvailable: true, systemPowerIsEstimated: false
        )
        let dict = snap.toJSON()
        let parsed = try #require(BatterySnapshot.from(remoteJSON: dict))
        #expect(parsed.id == snap.id)
        #expect(parsed.wattage == 14.2)
        #expect(parsed.batteryPower == 22.4)
        #expect(parsed.systemPowerAvailable == true)
        #expect(parsed.systemPowerIsEstimated == false)
        #expect(parsed.dirty == false)
    }

    @Test func remoteJSONLegacyFieldsDeriveSemantics() throws {
        // 远端旧格式：只有 watt，无新字段 → 与本地 v1 解码规则一致
        let dict: [String: Any] = [
            "id": UUID().uuidString,
            "ts": 1_720_780_800.0,
            "level": 70.0,
            "charging": true,
            "watt": 25.0,
            "temp": 31.0,
            "screen": true,
        ]
        let parsed = try #require(BatterySnapshot.from(remoteJSON: dict))
        #expect(parsed.isCharging)
        #expect(parsed.systemPowerAvailable == false)
        #expect(parsed.batteryPower == 25.0)
        #expect(parsed.dirty == false)
    }

    @Test func remoteJSONRejectsMalformedLines() {
        #expect(BatterySnapshot.from(remoteJSON: [:]) == nil)
        #expect(BatterySnapshot.from(remoteJSON: ["id": "not-a-uuid", "ts": 1.0]) == nil)
        #expect(BatterySnapshot.from(remoteJSON: ["ts": 1.0]) == nil)
    }

    @Test func toJSONContainsNewKeys() {
        let snap = BatterySnapshot(timestamp: base, level: 10, isCharging: false, wattage: 2, temperature: 30, screenOn: false)
        let keys = Set(snap.toJSON().keys)
        #expect(keys.isSuperset(of: ["id", "ts", "level", "charging", "watt", "batteryWatt",
                                     "powerAvailable", "powerEstimated", "temp", "screen", "cpu", "gpu", "disp", "dram"]))
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
        // ±5 分钟内的时钟偏差不丢数据
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
        // 裁掉的是最旧的（snaps.last），最新的（snaps[0]）保留
        #expect(!retained.contains { $0.id == snaps.last!.id })
        #expect(retained.contains { $0.id == snaps[0].id })
    }

    @Test func outputSortedByTimestamp() {
        let snaps = Array(makeSnaps([-3, -1, -2], now: now).shuffled())
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.map(\.timestamp) == retained.map(\.timestamp).sorted())
    }
}
