import Testing
import Foundation
@testable import BatteryBar

/// BatterySnapshot 的 toJSON / 初始化 / Codable 测试
@Suite struct BatterySnapshotTests {

    @Test func toJSONShape() {
        let snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_720_780_800),
            level: 78.5,
            isCharging: true,
            wattage: 45.2,
            temperature: 32.4,
            screenOn: true
        )

        let json = snap.toJSON()

        #expect(json["ts"] as? Double == 1_720_780_800)
        #expect(json["level"] as? Double == 78.5)
        #expect(json["charging"] as? Bool == true)
        #expect(json["watt"] as? Double == 45.2)
        #expect(json["temp"] as? Double == 32.4)
        #expect(json["screen"] as? Bool == true)
        #expect(json["id"] as? String == snap.id.uuidString)
    }

    @Test func initDefaultsDirtyToTrue() {
        let snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: 0),
            level: 50,
            isCharging: false,
            wattage: 0,
            temperature: 25,
            screenOn: false
        )

        #expect(snap.dirty == true)
    }

    @Test func codableRoundTrip() throws {
        let snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_720_780_800),
            level: 42.0,
            isCharging: false,
            wattage: -3.5,
            temperature: 28.1,
            screenOn: false
        )

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: data)

        #expect(decoded.id == snap.id)
        #expect(decoded.timestamp == snap.timestamp)
        #expect(abs(decoded.level - snap.level) < 0.0001)
        #expect(decoded.isCharging == snap.isCharging)
        #expect(abs(decoded.wattage - snap.wattage) < 0.0001)
        #expect(abs(decoded.temperature - snap.temperature) < 0.0001)
        #expect(decoded.screenOn == snap.screenOn)
        #expect(decoded.dirty == snap.dirty)
    }

    @Test func toJSONContainsExpectedKeys() {
        let snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: 1),
            level: 10,
            isCharging: false,
            wattage: 2,
            temperature: 30,
            screenOn: false
        )
        let dict = snap.toJSON()
        let keys = Set(dict.keys)
        #expect(keys.isSuperset(of: ["id", "ts", "level", "charging", "watt", "temp", "screen"]))
    }

    @Test func identifiableUsesStableID() {
        let snap = BatterySnapshot(
            timestamp: Date(),
            level: 0,
            isCharging: false,
            wattage: 0,
            temperature: 0,
            screenOn: false
        )
        // 同一个 snapshot 多次访问 id 应一致
        #expect(snap.id == snap.id)
    }
}
