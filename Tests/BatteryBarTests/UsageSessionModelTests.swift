import Testing
import Foundation
@testable import BatteryBar

/// 概览页时段分析模型：按 externalConnected 分段、lastCharge 有效性校验。
@MainActor
@Suite struct UsageSessionModelTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snap(_ minutesAfter: Double, level: Double, ext: Bool?, charging: Bool = false,
                      batteryPower: Double = 0) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: base.addingTimeInterval(minutesAfter * 60),
            level: level, isCharging: charging, wattage: batteryPower,
            temperature: 0, screenOn: true,
            batteryPower: batteryPower,
            externalConnected: ext
        )
    }

    /// 离电时段按插拔状态分段：接电点不进入离电曲线；
    /// 来源未知的旧点不参与分段。
    @Test func dischargeSessionSegmentsByExternalConnected() {
        var snaps: [BatterySnapshot] = []
        // 接电静置（优化充电暂停形态）30 分钟：level=100 不动
        for i in 0..<30 { snaps.append(snap(Double(i), level: 100, ext: true)) }
        // 拔电：60 分钟内 100→70
        for i in 0..<60 { snaps.append(snap(Double(30 + i), level: 100 - Double(i) * 0.5, ext: false, batteryPower: 8)) }
        // 中间混入来源未知的旧点（不得画进当前时段）
        snaps.append(snap(Double(50), level: 5, ext: nil))

        let model = UsageSessionModel()
        model.reload(snapshots: snaps, kind: .currentDischarge)

        #expect(!model.points.isEmpty)
        #expect(model.points.allSatisfy { $0.level >= 69 })          // 接电段与未知点不进曲线
        #expect(model.points.first!.level == 100)
        #expect(abs(model.summary.deltaPercent - 29.5) < 0.01)        // 只计真实放电（100→70.5）
        #expect(model.summary.avgBatteryWatts > 7 && model.summary.avgBatteryWatts < 9)
    }

    /// 反例：只有"接电未充电"数据（满电保持数小时）时，不存在离电时段。
    @Test func pausedChargingAloneYieldsNoDischargeSession() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<240 { snaps.append(snap(Double(i), level: 100, ext: true)) }

        let model = UsageSessionModel()
        model.reload(snapshots: snaps, kind: .currentDischarge)
        #expect(model.points.isEmpty)
        #expect(model.summary == UsageSessionModel.Summary())

        // 全部为来源未知（旧 v1/v2 数据）时同样没有可确认的离电时段
        var legacy: [BatterySnapshot] = []
        for i in 0..<120 { legacy.append(snap(Double(i), level: 99.5 - Double(i) * 0.01, ext: nil)) }
        model.reload(snapshots: legacy, kind: .currentDischarge)
        #expect(model.points.isEmpty)
    }

    /// 上次充电摘要：正电量变化 + 足够时长才展示。
    @Test func lastChargeRequiresPositiveGainAndDuration() {
        // 形态一：100%→100%（已充入 0%）→ 禁止出摘要
        var flat: [BatterySnapshot] = []
        for i in 0..<120 { flat.append(snap(Double(i), level: 100, ext: true, batteryPower: 2)) }
        let m1 = UsageSessionModel()
        m1.reload(snapshots: flat, kind: .lastCharge)
        #expect(m1.points.isEmpty)
        #expect(m1.cardTitle.contains("上次充电"))

        // 形态二：时长不足 5 分钟 → 禁止
        var brief: [BatterySnapshot] = []
        for i in 0..<4 { brief.append(snap(Double(i), level: 80 + Double(i) * 5, ext: true, charging: true, batteryPower: 30)) }
        let m2 = UsageSessionModel()
        m2.reload(snapshots: brief, kind: .lastCharge)
        #expect(m2.points.isEmpty)

        // 正例：55%→95%、40 分钟 → 有效摘要
        var good: [BatterySnapshot] = []
        for i in 0..<40 { good.append(snap(Double(i), level: 55 + Double(i), ext: true, charging: true, batteryPower: 28)) }
        let m3 = UsageSessionModel()
        m3.reload(snapshots: good, kind: .lastCharge)
        #expect(!m3.points.isEmpty)
        #expect(abs(m3.summary.deltaPercent - 39) < 0.01)
        #expect(m3.summary.avgBatteryWatts > 27 && m3.summary.avgBatteryWatts < 29)
    }

    /// 当前充电时段按 externalConnected 分段，暂停期 0W 不稀释平均功率。
    @Test func chargeSessionAveragesOnlyPositiveBatteryPower() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<20 { snaps.append(snap(Double(i), level: 50 + Double(i), ext: true, charging: true, batteryPower: 25)) }
        // 充电暂停 30 分钟：level 平坦、batteryPower≈0
        for i in 0..<30 { snaps.append(snap(Double(20 + i), level: 70, ext: true, charging: false, batteryPower: 0.1)) }

        let model = UsageSessionModel()
        model.reload(snapshots: snaps, kind: .currentCharge)

        #expect(!model.points.isEmpty)
        #expect(abs(model.summary.deltaPercent - 20) < 0.01)          // 50→70
        #expect(model.summary.avgBatteryWatts > 24 && model.summary.avgBatteryWatts < 26)
        #expect(model.isCharging)
    }

    /// 接电时段对用户称「本次接电」，不无条件称「本次充电」。
    @Test func currentChargeCardTitleIsPluggedSession() {
        let model = UsageSessionModel()
        model.reload(snapshots: [], kind: .currentCharge)
        #expect(model.cardTitle.contains("本次接电"))
        #expect(!model.cardTitle.contains("本次充电"))
    }

    /// 展示模型反例：ext=true、100→97（接电时段电量下降）→ 中性「电量变化 -3%」，
    /// 不得绿色高亮、不得出现「已充入 -3%」。
    @Test func pluggedSessionNegativeDeltaShowsNeutralDisplay() {
        // 时段内电量从 100 降到 97（例如接电但高负载）
        var snaps: [BatterySnapshot] = []
        for i in 0..<4 { snaps.append(snap(Double(i), level: 100 - Double(i), ext: true, batteryPower: 20)) }
        let model = UsageSessionModel()
        model.reload(snapshots: snaps, kind: .currentCharge)

        #expect(model.summary.startLevel == 100)
        #expect(model.summary.endLevel == 97)
        #expect(abs(model.summary.deltaPercent - (-3)) < 0.001)

        let display = UsageSessionModel.chargeDeltaDisplay(deltaPercent: model.summary.deltaPercent)
        #expect(display.label == "电量变化")
        #expect(display.text == "-3%")
        #expect(!display.isGain)

        // 视图不再渲染「已充入 -3%」：label 与「已充入」完全不同
        #expect(display.label != "已充入")
    }

    /// 正增长 → 「电量增加 +N%」；零增长 → 中性「电量变化 0%」。
    @Test func chargeDeltaDisplaySemantics() {
        let gain = UsageSessionModel.chargeDeltaDisplay(deltaPercent: 5)
        #expect(gain.label == "电量增加")
        #expect(gain.text == "+5%")
        #expect(gain.isGain)

        let zero = UsageSessionModel.chargeDeltaDisplay(deltaPercent: 0)
        #expect(zero.label == "电量变化")
        #expect(zero.text == "0%")
        #expect(!zero.isGain)

        let negative = UsageSessionModel.chargeDeltaDisplay(deltaPercent: -3)
        #expect(negative.label == "电量变化")
        #expect(negative.text == "-3%")
        #expect(!negative.isGain)
    }

    /// lastCharge 门槛不变：100→100（0% 增长）仍禁止出摘要。
    @Test func lastChargeThresholdUnchangedStillRejectsFlatSession() {
        var flat: [BatterySnapshot] = []
        for i in 0..<120 { flat.append(snap(Double(i), level: 100, ext: true, batteryPower: 2)) }
        let model = UsageSessionModel()
        model.reload(snapshots: flat, kind: .lastCharge)
        #expect(model.points.isEmpty)
    }
}
