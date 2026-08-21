import SwiftUI
import Charts
import Observation

/// UsageTab 的视图状态模型（@Observable 说明见 CycleTabModel）
@Observable
final class UsageTabModel {
    var snapshots: [BatterySnapshot] = []
    var lastSnapshotUpdate: Date = .distantPast
    var selectedPoint: (relMin: Double, level: Double, time: Date)?
}

struct UsageTab: View {
    @ObservedObject var sampler: PowerSampler
    var model: UsageTabModel

    // 读侧透传：body 内沿用原属性名，改动面最小
    private var snapshots: [BatterySnapshot] { model.snapshots }
    private var selectedPoint: (relMin: Double, level: Double, time: Date)? { model.selectedPoint }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. 状态英雄卡片
                statusHeroCard

                // 2. 关键指标 4 格（循环/健康度/温度/容量）
                metricsGrid

                // 3. 电量曲线（满电不显示）
                if !isFullCharge {
                    chartCard
                    cycleSummaryCard
                }

                // 4. 满电时显示充电摘要
                if isFullCharge {
                    chargeSessionCard
                }

                // 5. 使用时间统计
                // 离电时显示当前周期统计；充电时显示上次离电周期统计
                usageStatsRow

                // 6. 电池信息卡片
                batteryInfoCard
            }
            .padding(20)
        }
        .onAppear {
            model.snapshots = DataStore.shared.allSnapshots()
            model.lastSnapshotUpdate = Date()
        }
        // 快照数组 60s 节流刷新（与 CycleTab 同模式）；
        // 实时数值由 sampler @Published 变化驱动，不再订阅每秒 tick
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            let now = Date()
            if now.timeIntervalSince(model.lastSnapshotUpdate) > 50 {
                model.snapshots = DataStore.shared.allSnapshots()
                model.lastSnapshotUpdate = now
            }
        }
    }

    // MARK: - 状态判断

    /// 是否连接电源（拔电后立即变为 false，不依赖电量百分比）
    private var isPluggedIn: Bool {
        sampler.currentInfo?.externalConnected ?? false
    }

    /// 满电状态：必须同时满足"连接电源"且"电量 >= 100"。
    /// 拔电后即使电量还是 100%，也按离电处理（显示耗电曲线 + 续航预估）。
    private var isFullCharge: Bool {
        isPluggedIn && sampler.currentLevel >= 100
    }

    private var statusColor: Color {
        if isFullCharge { return .green }
        if sampler.currentIsCharging { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .accentColor
    }

    private var statusIcon: String {
        if isFullCharge { return "checkmark.circle.fill" }
        if sampler.currentIsCharging { return "bolt.fill" }
        if sampler.currentLevel <= 20 { return "battery.25percent" }
        return "battery.75percent"
    }

    // MARK: - 1. 状态英雄卡片

    @ViewBuilder
    private var statusHeroCard: some View {
        if isFullCharge {
            fullChargeHero
        } else if sampler.currentIsCharging {
            chargingHero
        } else {
            dischargingHero
        }
    }

    private var fullChargeHero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: statusIcon).font(.system(size: 26)).foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("电池已充满").font(.title2.bold())
                Text("已连接电源适配器")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.0f%%", sampler.systemHealthPercent))
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.green)
                Text("健康度").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
    }

    private var chargingHero: some View {
        let remaining = estimatedChargeTime()
        let hours = Int(remaining / 3600)
        let mins = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)

        return HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: statusIcon).font(.system(size: 26)).foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("充电中").font(.title2.bold()).foregroundStyle(.green)
                if remaining > 0 {
                    Text("预计 \(hours)h \(mins)m 后充满")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("计算中...").font(.subheadline).foregroundStyle(.secondary)
                }
                if sampler.currentLevel >= 80 {
                    Text(sampler.currentLevel >= 95 ? "涓流充电阶段" : "减速充电阶段")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(sampler.currentLevel))")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text("%").font(.title3).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1fW", sampler.currentWattage))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
    }

    private var dischargingHero: some View {
        let rate = sampler.cachedDrainRate
        // 考虑5%放电截止保护：电量到5%会自动关机，实际可用电量为 level - 5
        let usableLevel = max(0, sampler.currentLevel - 5)
        let remaining = rate > 0 ? usableLevel / rate : 0
        let hours = Int(remaining); let mins = Int((remaining - Double(hours)) * 60)
        let hasEstimate = rate > 0

        return HStack(spacing: 16) {
            ZStack {
                Circle().fill(statusColor.opacity(0.12)).frame(width: 56, height: 56)
                Image(systemName: statusIcon).font(.system(size: 26)).foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("预估续航").font(.caption).foregroundStyle(.secondary)
                if hasEstimate {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(hours)")
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                        Text("h \(mins)m").font(.title3).foregroundStyle(.secondary)
                    }
                } else {
                    Text("计算中...")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(sampler.currentLevel))")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text("%").font(.title3).foregroundStyle(.secondary)
                }
                Text(String(format: "%.1fW", sampler.currentWattage))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
    }

    // MARK: - 2. 关键指标 4 格

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricTile("循环", value: "\(sampler.currentInfo?.cycleCount ?? 0)", unit: "次", icon: "arrow.triangle.2.circlepath", color: .blue)
            metricTile("健康度", value: String(format: "%.0f", sampler.systemHealthPercent), unit: "%", icon: "heart.fill", color: .green)
            metricTile("温度", value: sampler.currentTemperature > 0.5 ? String(format: "%.1f", sampler.currentTemperature) : "—", unit: sampler.currentTemperature > 0.5 ? "°C" : "", icon: "thermometer", color: .orange)
            metricTile("容量", value: capacityString, unit: "mAh", icon: "battery.100", color: .indigo)
        }
    }

    private func metricTile(_ label: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
        }
    }

    private var capacityString: String {
        guard let info = sampler.currentInfo, info.maxCapacity > 0 else { return "—" }
        return "\(info.maxCapacity)"
    }

    // MARK: - 3. 电量曲线

    /// 当前周期起点：找最后一次"切换到当前状态"的点。
    /// 离电时返回拔电后第一个放电点；充电时返回插电后第一个充电点。
    private func currentCycleStart() -> Date? {
        guard !isFullCharge else { return nil }
        let targetCharging = sampler.currentIsCharging
        var prevCharging: Bool?
        var lastSwitch: Date?
        for snap in snapshots {
            if let prev = prevCharging, prev != snap.isCharging {
                // snap 是切换后的第一个点
                if snap.isCharging == targetCharging {
                    lastSwitch = snap.timestamp
                }
            }
            prevCharging = snap.isCharging
        }
        // 没找到切换点，但有数据且状态一致：从第一个同状态点开始
        if lastSwitch == nil {
            for snap in snapshots where snap.isCharging == targetCharging {
                return snap.timestamp
            }
        }
        return lastSwitch ?? snapshots.first?.timestamp
    }

    @ViewBuilder
    private var chartCard: some View {
        if let start = currentCycleStart() {
            let recent = snapshots.filter { $0.timestamp >= start }.sorted { $0.timestamp < $1.timestamp }
            let points = filterChangedPoints(recent: recent, start: start)
            let windowMin = max(30, ceil((points.last?.relMin ?? 0) / 30) * 30)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(sampler.currentIsCharging ? "充电曲线" : "耗电曲线")
                        .font(.subheadline.bold())
                    Spacer()
                    if let first = recent.first {
                        Text("起始 \(Int(first.level))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                if points.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "chart.line.uptrend.xyaxis").font(.title2).foregroundStyle(.tertiary)
                            Text("数据采集中...").font(.caption).foregroundStyle(.secondary)
                        }.frame(height: 140)
                        Spacer()
                    }
                } else {
                    chartContent(points: points, windowMin: windowMin)
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
            }
        }
    }

    /// 只保留电量有变化的点，避免电量不变时往右画水平线
    private func filterChangedPoints(recent: [BatterySnapshot], start: Date) -> [(relMin: Double, level: Double, time: Date)] {
        var filtered: [BatterySnapshot] = []
        var lastLevel: Double? = nil
        for snap in recent {
            if lastLevel == nil || snap.level != lastLevel {
                filtered.append(snap)
                lastLevel = snap.level
            }
        }
        if let last = recent.last, filtered.last?.id != last.id {
            filtered.append(last)
        }
        return filtered.map { snap in
            (snap.timestamp.timeIntervalSince(start) / 60, snap.level, snap.timestamp)
        }
    }

    /// 生成 X 轴刻度数组
    private func strideValues(from: Double, to: Double, by: Double) -> [Double] {
        var result: [Double] = []
        var v = from
        while v <= to + 0.001 {
            result.append(v)
            v += by
        }
        return result
    }

    /// 曲线图表内容（拆分出来避免编译器超时）
    private func chartContent(points: [(relMin: Double, level: Double, time: Date)], windowMin: Double) -> some View {
        let lineColor: Color = sampler.currentIsCharging ? .green : .accentColor
        let startTime = points.first?.time ?? Date()
        let stepMin = strideStep(windowMin)
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                lineMark(p: p, color: lineColor)
                areaMark(p: p, color: lineColor)
            }
            if let selected = selectedPoint {
                RuleMark(x: .value("时长", selected.relMin))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                PointMark(x: .value("时长", selected.relMin), y: .value("电量", selected.level))
                    .annotation(position: .top, alignment: .center) {
                        selectedAnnotation(selected)
                    }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedPoint?.relMin ?? 0 },
            set: { x in
                if let xv = x {
                    selectClosestPoint(x: xv, points: points)
                }
            }
        ))
        .chartXAxis {
            AxisMarks(values: strideValues(from: 0, to: windowMin, by: stepMin)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        let absTime = startTime.addingTimeInterval(v * 60)
                        Text(absTime, format: .dateTime.hour().minute())
                    }
                }
                AxisGridLine()
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) {
                AxisValueLabel().foregroundStyle(.primary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2])).foregroundStyle(.quaternary)
            }
        }
        .chartXScale(domain: 0...windowMin)
        .chartYScale(domain: 0...100)
        .frame(height: 140)
    }

    @ChartContentBuilder
    private func lineMark(p: (relMin: Double, level: Double, time: Date), color: Color) -> some ChartContent {
        LineMark(x: .value("时长", p.relMin), y: .value("电量", p.level))
            .foregroundStyle(color)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
    }

    @ChartContentBuilder
    private func areaMark(p: (relMin: Double, level: Double, time: Date), color: Color) -> some ChartContent {
        AreaMark(x: .value("时长", p.relMin), yStart: .value("底", 0), yEnd: .value("电量", p.level))
            .foregroundStyle(LinearGradient(
                colors: [color.opacity(0.1), color.opacity(0)],
                startPoint: .top, endPoint: .bottom))
    }

    /// 根据窗口大小决定刻度间隔
    private func strideStep(_ windowMin: Double) -> Double {
        if windowMin <= 60 { return 10 }      // ≤1h: 每10分钟
        if windowMin <= 180 { return 30 }     // ≤3h: 每30分钟
        if windowMin <= 360 { return 60 }     // ≤6h: 每1小时
        return 120                              // >6h: 每2小时
    }

    /// 选中点的标注视图
    private func selectedAnnotation(_ selected: (relMin: Double, level: Double, time: Date)) -> some View {
        VStack(spacing: 2) {
            Text(selected.time, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
            Text("\(Int(selected.level))%").font(.caption.bold())
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// 选中最近的数据点
    private func selectClosestPoint(x: Double, points: [(relMin: Double, level: Double, time: Date)]) {
        var best: (relMin: Double, level: Double, time: Date)?
        var bestDiff = Double.infinity
        for p in points {
            let diff = abs(p.relMin - x)
            if diff < bestDiff {
                bestDiff = diff
                best = p
            }
        }
        if let b = best {
            model.selectedPoint = b
        }
    }

    // MARK: - 周期摘要（只显示充入/耗电百分比和功耗，时间统计由 usageStatsRow 负责）

    @ViewBuilder
    private var cycleSummaryCard: some View {
        if let start = currentCycleStart() {
            let snaps = snapshots.filter { $0.timestamp >= start }
            if snaps.count >= 2, let first = snaps.first, let last = snaps.last {
                let isCharging = sampler.currentIsCharging
                let levelDelta = isCharging ? (last.level - first.level) : (first.level - last.level)
                let avgWattage = snaps.map { abs($0.wattage) }.reduce(0, +) / Double(snaps.count)

                HStack(spacing: 16) {
                    miniStat(isCharging ? "已充入" : "耗电", value: "\(Int(levelDelta.rounded()))%", highlight: true)
                    Spacer()
                    miniStat("平均功耗", value: String(format: "%.1fW", avgWattage))
                    miniStat("起始", value: "\(Int(first.level))%")
                    miniStat("当前", value: "\(Int(last.level))%")
                }
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
                }
            }
        }
    }

    private func miniStat(_ label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: highlight ? 18 : 13, weight: highlight ? .bold : .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(highlight ? .green : .primary)
        }
    }

    // MARK: - 4. 满电：充电摘要

    private func lastChargeSession() -> (start: Date, end: Date, startLevel: Double, endLevel: Double, avgWattage: Double, peakWattage: Double)? {
        guard snapshots.count >= 2 else { return nil }
        var chargeStartIndex: Int?
        for i in (1..<snapshots.count).reversed() {
            if !snapshots[i-1].isCharging && snapshots[i].isCharging {
                chargeStartIndex = i
                break
            }
        }
        if chargeStartIndex == nil && snapshots.last?.isCharging == true {
            chargeStartIndex = snapshots.firstIndex(where: { $0.isCharging }) ?? 0
        }
        guard let startIdx = chargeStartIndex else { return nil }

        var endIdx = snapshots.count - 1
        for i in startIdx..<snapshots.count {
            if snapshots[i].level >= 100 || (i > startIdx && !snapshots[i].isCharging) {
                endIdx = i
                break
            }
        }

        let session = Array(snapshots[startIdx...endIdx])
        guard let first = session.first, let last = session.last else { return nil }
        let watts = session.map { abs($0.wattage) }.filter { $0 > 0 }
        let avgWattage = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)
        let peakWattage = watts.max() ?? 0
        return (first.timestamp, last.timestamp, first.level, last.level, avgWattage, peakWattage)
    }

    @ViewBuilder
    private var chargeSessionCard: some View {
        if let s = lastChargeSession() {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("充电摘要").font(.subheadline.bold()).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "bolt.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                }

                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("充满耗时").font(.caption2).foregroundStyle(.secondary)
                        Text(formatHoursMinutes(s.end.timeIntervalSince(s.start)))
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("充入电量").font(.caption2).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(s.endLevel.rounded()) - Int(s.startLevel.rounded()))")
                                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.green)
                            Text("%").font(.headline).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开始").font(.caption2).foregroundStyle(.secondary)
                        Text(s.start, format: .dateTime.hour().minute())
                            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("结束").font(.caption2).foregroundStyle(.secondary)
                        Text(s.end, format: .dateTime.hour().minute())
                            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    }
                }

                HStack(spacing: 12) {
                    labelStat("平均", value: String(format: "%.1fW", s.avgWattage), icon: "bolt")
                    labelStat("峰值", value: String(format: "%.1fW", s.peakWattage), icon: "bolt.fill")
                    labelStat("协议", value: sampler.currentInfo?.adapterProtocol ?? "—", icon: "powerplug")
                    labelStat("适配器", value: adapterWattsString, icon: "power")
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
            }
        }
    }

    // MARK: - 5. 使用时间统计

    private var usageStatsRow: some View {
        let isDischarging = !isPluggedIn
        let screenMin = isDischarging ? sampler.screenOnTime : sampler.lastScreenOnTime
        let sleepMin = isDischarging ? sampler.sleepTime : sampler.lastSleepTime
        let totalMin = screenMin + sleepMin
        let label = isDischarging ? "本次使用" : "上次使用"

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.subheadline.bold()).foregroundStyle(.secondary)
                Spacer()
                if !isDischarging && totalMin == 0 {
                    Text("暂无记录").font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 10) {
                statCard("亮屏", minutes: screenMin, icon: "sun.max.fill", color: .yellow)
                statCard("休眠", minutes: sleepMin, icon: "moon.fill", color: .indigo)
                statCard("总计", minutes: totalMin, icon: "clock.fill", color: .blue)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private func statCard(_ title: String, minutes: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
            Text(formatMinutes(minutes)).font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    // MARK: - 6. 电池信息卡片

    private var batteryInfoCard: some View {
        let info = sampler.currentInfo
        return VStack(alignment: .leading, spacing: 10) {
            Text("电池信息").font(.subheadline.bold()).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                infoTile("制造商", value: info?.manufacturer ?? "—", icon: "building.2")
                infoTile("序列号", value: info?.serialNumber ?? "—", icon: "number")
                infoTile("设备名称", value: info?.deviceName ?? "—", icon: "laptopcomputer")
                infoTile("设计容量", value: "\(info?.designCapacity ?? 0) mAh", icon: "doc.text")
                infoTile("电压", value: String(format: "%.0f mV", sampler.currentVoltage), icon: "bolt")
                infoTile("电流", value: String(format: "%.0f mA", sampler.currentAmperage), icon: "arrow.left.arrow.right")
                infoTile("充电协议", value: info?.adapterProtocol ?? "—", icon: "powerplug")
                infoTile("适配器功率", value: adapterWattsString, icon: "power")
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private func infoTile(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)) }
    }

    // MARK: - 辅助

    private var adapterWattsString: String {
        guard let info = sampler.currentInfo, info.adapterWatts > 0 else { return "—" }
        return String(format: "%.0f W", info.adapterWatts)
    }

    private func labelStat(_ label: String, value: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// 充电预计时间（秒）。
    /// 使用滑动平均充电速率 + 精细分段效率曲线 + 温控因素。
    private func estimatedChargeTime() -> TimeInterval {
        let level = sampler.currentLevel
        let snaps = DataStore.shared.recentSnapshots(1440)
        let chargingSnaps = snaps.filter { $0.isCharging }.sorted { $0.timestamp < $1.timestamp }
        guard chargingSnaps.count >= 2 else { return 0 }

        // === 1. 滑动窗口计算多点速率，取中位数平滑 ===
        // 用10分钟窗口，避免刚开始充电时速率不稳
        var windowRates: [Double] = []
        let windowSize = min(10, max(2, chargingSnaps.count / 3))
        for i in 0..<(chargingSnaps.count - windowSize) {
            let start = chargingSnaps[i]
            let end = chargingSnaps[i + windowSize]
            let hours = end.timestamp.timeIntervalSince(start.timestamp) / 3600
            if hours > 0 {
                let r = abs(end.level - start.level) / hours
                if r > 0 { windowRates.append(r) }
            }
        }

        let rate: Double
        if !windowRates.isEmpty {
            windowRates.sort()
            rate = windowRates[windowRates.count / 2] // 中位数
        } else {
            // 数据太少，用整体速率
            let hours = chargingSnaps.last!.timestamp.timeIntervalSince(chargingSnaps.first!.timestamp) / 3600
            guard hours > 0 else { return 0 }
            rate = abs(chargingSnaps.last!.level - chargingSnaps.first!.level) / hours
        }
        guard rate > 0 else { return 0 }

        // === 2. 分段估算，每段5% ===
        // 充电效率曲线（基于实际锂离子电池充电特性）：
        //  - 0-50%: 恒流快充，效率 1.0
        //  - 50-75%: 电流开始下降，效率 0.85
        //  - 75-85%: 减速充电，效率 0.65
        //  - 85-90%: 明显减速，效率 0.45
        //  - 90-95%: 涓流阶段，效率 0.30
        //  - 95-100%: 极慢涓流，效率 0.15
        var totalHours = 0.0
        var currentLevel = level
        while currentLevel < 100 {
            let segmentEnd = min(currentLevel + 5, 100)
            let segmentRemain = segmentEnd - currentLevel
            let efficiency: Double
            switch currentLevel {
            case 95...: efficiency = 0.15
            case 90..<95: efficiency = 0.30
            case 85..<90: efficiency = 0.45
            case 75..<85: efficiency = 0.65
            case 50..<75: efficiency = 0.85
            default: efficiency = 1.0
            }

            // === 3. 温控因素 ===
            // 锂电池充电最佳温度 15-35°C
            //  - > 45°C: 高温保护，大幅降速
            //  - 40-45°C: 减速
            //  - 35-40°C: 轻微减速
            //  - 15-35°C: 正常
            //  - < 15°C: 低温减速
            let temp = sampler.currentTemperature
            let tempFactor: Double
            if temp <= 0.5 {
                // 温度不可用（Apple Silicon 部分系统不暴露 Temperature 键）：不惩罚
                tempFactor = 1.0
            } else {
            switch temp {
            case 45...: tempFactor = 0.3
            case 40..<45: tempFactor = 0.6
            case 35..<40: tempFactor = 0.85
            case 15..<35: tempFactor = 1.0
            case 10..<15: tempFactor = 0.7
            case 5..<10: tempFactor = 0.4
            default: tempFactor = 0.2 // 极低温
            }
            }

            let adjustedRate = rate * efficiency * tempFactor
            guard adjustedRate > 0 else { break }
            totalHours += segmentRemain / adjustedRate
            currentLevel = segmentEnd
        }

        return totalHours * 3600
    }

    private func formatMinutes(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }

    private func formatHoursMinutes(_ seconds: TimeInterval) -> String {
        let total = Int(seconds / 60)
        return "\(total / 60)h \(total % 60)m"
    }
}
