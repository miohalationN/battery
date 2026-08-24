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

    @Test func contextualPowerStateRoundTripRemainsOptionalForLegacyData() throws {
        let current = BatterySnapshot(
            timestamp: base, level: 55, isCharging: false, wattage: 8,
            temperature: 31, screenOn: true, externalConnected: false,
            lowPowerModeEnabled: true, thermalState: "偏高"
        )
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(current))
        #expect(decoded.lowPowerModeEnabled == true)
        #expect(decoded.thermalState == "偏高")

        let legacyJSON = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":50,"isCharging":false,
         "wattage":7.0,"temperature":30.0,"screenOn":true}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(BatterySnapshot.self, from: legacyJSON)
        #expect(legacy.lowPowerModeEnabled == nil)
        #expect(legacy.thermalState == nil)
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
        #expect(!parsed.isCharging)                      // 未充电的旧离电点
        #expect(parsed.systemPowerAvailable == true)     // v1 规则：!isCharging → 标可用
        #expect(parsed.systemPowerIsEstimated == true)   // 且标估算
        #expect(parsed.batteryPower == 25.0)
        #expect(parsed.externalConnected == nil)         // 来源未知
        #expect(parsed.trustedSystemLoad == nil)         // → 估算负载保守排除
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

/// BatterySnapshot v5：分钟聚合字段、显示器亮度观测与 v1–v4 兼容。
@Suite struct SnapshotV5CompatTests {

    private let base = Date(timeIntervalSince1970: 1_720_780_800)
    private let windowStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// 旧 v4 JSON（无任何 v5 键）必须无损解码，v5 字段全部为 nil
    @Test func v4JSONDecodesWithAllV5FieldsNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":80,"isCharging":false,
         "wattage":9.5,"temperature":31.0,"screenOn":true,"externalConnected":false,
         "lowPowerModeEnabled":true,"thermalState":"正常"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.aggregateWindowStart == nil)
        #expect(snap.systemEnergyWh == nil)
        #expect(snap.systemPowerAverage == nil)
        #expect(snap.batteryChargeWh == nil)
        #expect(snap.temperatureAverage == nil)
        #expect(snap.screenOnFraction == nil)
        #expect(snap.displayBrightness == nil)
        #expect(snap.trustedSystemLoad == 9.5)
    }

    @Test func v5CodableRoundTrip() throws {
        var snap = BatterySnapshot(
            timestamp: base, level: 55, isCharging: false, wattage: 11,
            temperature: 30, screenOn: true, externalConnected: false
        )
        snap.apply(
            minuteAggregate: MinuteAggregate(
                windowStart: windowStart,
                systemEnergyWh: 0.15,
                systemPowerAverage: 9,
                systemPowerPeak: 12.5,
                systemCoverage: 1,
                batteryChargeWh: 0,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.15,
                batteryDischargeSeconds: 60,
                temperatureAverage: 29.5,
                temperatureMaximum: 31,
                temperatureCoverage: 1,
                screenOnFraction: 1,
                lowPowerModeFraction: 0,
                maximumThermalStateLabel: "正常",
                maximumThermalStateOrdinal: 0
            ),
            displayBrightness: 0.62,
            brightnessAvailable: true,
            brightnessReadAt: base
        )
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
    }

    @Test func remoteJSONV5RoundTripAndLegacyStaysNil() {
        var snap = BatterySnapshot(
            timestamp: base, level: 40, isCharging: false, wattage: 7,
            temperature: 28, screenOn: true, externalConnected: false
        )
        snap.aggregateWindowStart = windowStart
        snap.systemEnergyWh = 0.1
        snap.systemCoverage = 1
        snap.batteryDischargeWh = 0.1
        snap.displayBrightness = nil
        snap.brightnessAvailable = false

        var dict = snap.toJSON()
        let parsed = BatterySnapshot.from(remoteJSON: dict)!
        #expect(parsed.aggregateWindowStart == windowStart)
        #expect(parsed.systemEnergyWh == 0.1)
        #expect(parsed.brightnessAvailable == false)

        // 远端旧格式没有 v5 键 → 全部保持 nil，不推导
        for key in ["aggWin", "sysEWh", "sysPAvg", "sysPPeak", "sysCov", "batChgWh",
                    "batDisWh", "tAvg", "tMax", "tCov", "screenFrac", "lpmFrac",
                    "thermalPeak", "bright", "brightOK", "brightAt"] {
            dict.removeValue(forKey: key)
        }
        let legacy = BatterySnapshot.from(remoteJSON: dict)!
        #expect(legacy.aggregateWindowStart == nil)
        #expect(legacy.systemEnergyWh == nil)
        #expect(legacy.systemCoverage == nil)
        #expect(legacy.displayBrightness == nil)
    }

    /// 聚合写入按覆盖率门控：<0.8 不产生完整分钟指标；<0.5 温度趋势留空但覆盖率如实记录；
    /// 显示器亮度只记录原始量，绝不制造瓦数。
    @Test func aggregateApplyGatesByFrozenCoverageThresholds() {
        func make(_ systemCoverage: Double, _ tempCoverage: Double) -> MinuteAggregate {
            MinuteAggregate(
                windowStart: windowStart,
                systemEnergyWh: 0.1666,
                systemPowerAverage: 10,
                systemPowerPeak: 14,
                systemCoverage: systemCoverage,
                batteryChargeWh: 0.2,
                batteryChargeSeconds: 30,
                batteryDischargeWh: 0.05,
                batteryDischargeSeconds: 20,
                temperatureAverage: 30,
                temperatureMaximum: 33,
                temperatureCoverage: tempCoverage,
                screenOnFraction: 1,
                lowPowerModeFraction: 0,
                maximumThermalStateLabel: "偏高",
                maximumThermalStateOrdinal: 1
            )
        }

        var sparse = BatterySnapshot(
            timestamp: base, level: 50, isCharging: false, wattage: 3,
            temperature: 30, screenOn: true, externalConnected: false
        )
        sparse.apply(
            minuteAggregate: make(0.4, 0.3),
            displayBrightness: nil, brightnessAvailable: false, brightnessReadAt: nil
        )
        #expect(sparse.systemEnergyWh == nil)
        #expect(sparse.systemPowerAverage == nil)
        #expect(sparse.systemPowerPeak == nil)
        #expect(sparse.temperatureAverage == nil)
        #expect(sparse.temperatureMaximum == nil)
        #expect(sparse.systemCoverage == 0.4)
        #expect(sparse.temperatureCoverage == 0.3)
        // 能量分项（充/放）与离散份额不受系统覆盖率门控，如实记录
        #expect(sparse.batteryChargeWh == 0.2)
        #expect(sparse.batteryDischargeWh == 0.05)
        #expect(sparse.screenOnFraction == 1)
        #expect(sparse.maximumThermalState == "偏高")

        var full = BatterySnapshot(
            timestamp: base, level: 50, isCharging: false, wattage: 10,
            temperature: 30, screenOn: true, externalConnected: false
        )
        full.apply(
            minuteAggregate: make(1.0, 0.9),
            displayBrightness: 0.5, brightnessAvailable: true, brightnessReadAt: base
        )
        #expect(full.systemEnergyWh == 0.1666)
        #expect(full.systemPowerAverage == 10)
        #expect(full.temperatureAverage == 30)
        #expect(full.temperatureMaximum == 33)
        #expect(full.displayBrightness == 0.5)
        // 新快照不制造显示器瓦数
        #expect(full.displayPower == 0)
    }
}

/// 快照保留窗口：24 小时裁剪、未来异常点拒绝、硬上限。
@Suite struct RetentionPolicyTests {    private func makeSnaps(_ agesHours: [Double], now: Date) -> [BatterySnapshot] {
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
