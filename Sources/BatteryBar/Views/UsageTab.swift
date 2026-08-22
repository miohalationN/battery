import SwiftUI
import Charts

struct UsageTab: View {
    @Environment(PowerSampler.self) private var sampler
    @State private var session = UsageSessionModel()
    @State private var detailExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                PageHeader(
                    title: "电池概览",
                    subtitle: "续航、健康与当前充放电状态",
                    systemImage: statusIcon,
                    tint: statusColor,
                    badge: "\(Int(sampler.currentLevel))%"
                )

                StatusHero(sampler: sampler)

                healthMetricsGrid

                SessionTrendCard(model: session)

                usageStatsRow

                batteryDetailSection
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.top, 46)
            .padding(.bottom, BBDesign.pagePadding)
        }
        .onAppear {
            reloadSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
            reloadSession()
        }
        // 时段归属只随插拔/充满切换；重算在通知驱动的一处完成，body 不做任何扫描
        .onChange(of: sessionKind) {
            reloadSession()
        }
    }

    // MARK: - 时段模型（重算只发生在快照变化或时段切换）

    private func reloadSession() {
        session.reload(snapshots: DataStore.shared.allSnapshots(), kind: sessionKind)
    }

    /// 是否连接电源（拔电后立即变为 false，不依赖电量百分比）
    private var isPluggedIn: Bool {
        sampler.currentInfo?.externalConnected ?? false
    }

    /// 满电状态：必须同时满足"连接电源"且"电量 >= 100"。
    /// 拔电后即使电量还是 100%，也按离电处理（显示耗电曲线 + 续航预估）。
    private var isFullCharge: Bool {
        isPluggedIn && sampler.currentLevel >= 100
    }

    private var sessionKind: UsageSessionModel.SessionKind {
        if isFullCharge { return .lastCharge }
        return sampler.currentIsCharging ? .currentCharge : .currentDischarge
    }

    private var statusColor: Color {
        if isFullCharge { return .green }
        if sampler.currentIsCharging { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .bbBlue
    }

    private var statusIcon: String {
        if isFullCharge { return "checkmark.circle.fill" }
        if sampler.currentIsCharging { return "bolt.fill" }
        if sampler.currentLevel <= 20 { return "battery.25percent" }
        return "battery.75percent"
    }

    // MARK: - 健康指标（低频字段：循环次数/健康度/温度/容量）

    private var healthMetricsGrid: some View {
        HStack(spacing: BBDesign.itemSpacing) {
            StatTile(icon: "heart.fill", tint: .bbMint, value: String(format: "%.0f", sampler.systemHealthPercent), unit: "%", label: "健康度")
            StatTile(icon: "arrow.triangle.2.circlepath", tint: .bbBlue, value: "\(sampler.currentInfo?.cycleCount ?? 0)", unit: "次", label: "循环次数")
            StatTile(icon: "thermometer", tint: .orange,
                     value: sampler.currentTemperature > 0.5 ? String(format: "%.1f", sampler.currentTemperature) : "—",
                     unit: sampler.currentTemperature > 0.5 ? "°C" : "", label: "温度")
            StatTile(icon: "battery.100", tint: .indigo, value: capacityString, unit: capacityString == "—" ? "" : "mAh", label: "满充容量")
        }
    }

    private var capacityString: String {
        guard let info = sampler.currentInfo, info.maxCapacity > 0 else { return "—" }
        return "\(info.maxCapacity)"
    }

    // MARK: - 使用时间统计

    private var usageStatsRow: some View {
        let isDischarging = !isPluggedIn
        let screenMin = isDischarging ? sampler.screenOnTime : sampler.lastScreenOnTime
        let sleepMin = isDischarging ? sampler.sleepTime : sampler.lastSleepTime
        let totalMin = screenMin + sleepMin
        let label = isDischarging ? "本次使用" : "上次使用"

        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: label, systemImage: "clock.fill", tint: .bbPurple)
                if !isDischarging && totalMin == 0 {
                    Text("暂无记录").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text("屏幕关闭期间计入右侧，不等同系统睡眠")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "sun.max.fill", tint: .bbAmber, value: formatMinutes(screenMin), unit: "", label: "亮屏")
                StatTile(icon: "moon.fill", tint: .indigo, value: formatMinutes(sleepMin), unit: "", label: "屏幕关闭/休眠")
                StatTile(icon: "clock.fill", tint: .bbBlue, value: formatMinutes(totalMin), unit: "", label: "总计")
            }
        }
        .glassCard(accent: .bbPurple)
    }

    // MARK: - 电池与电源详情（默认折叠）

    @ViewBuilder
    private var batteryDetailSection: some View {
        let info = sampler.currentInfo
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            DisclosureGroup(isExpanded: $detailExpanded) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    infoTile("设备名称", value: info?.deviceName ?? "—", icon: "laptopcomputer")
                    infoTile("制造商", value: info?.manufacturer ?? "—", icon: "building.2")
                    infoTile("序列号", value: info?.serialNumber ?? "—", icon: "number")
                    infoTile("设计容量", value: designCapacityString(info), icon: "doc.text")
                    infoTile("电压", value: sampler.currentVoltage > 0 ? String(format: "%.0f mV", sampler.currentVoltage) : "—", icon: "bolt")
                    infoTile("电流", value: sampler.currentAmperage != 0 ? String(format: "%.0f mA", sampler.currentAmperage) : "—", icon: "arrow.left.arrow.right")
                    infoTile("充电协议", value: info?.adapterProtocol ?? "—", icon: "powerplug")
                    infoTile("适配器额定", value: adapterWattsString, icon: "power")
                }
                .padding(.top, 6)
            } label: {
                SectionHeader(title: "电池与电源详情", systemImage: "info.circle.fill", tint: .bbTeal)
            }
        }
        .glassCard(accent: .bbTeal)
    }

    private func infoTile(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))
    }

    private var adapterWattsString: String {
        guard let info = sampler.currentInfo, info.adapterWatts > 0 else { return "—" }
        return String(format: "%.0f W", info.adapterWatts)
    }

    private func designCapacityString(_ info: BatteryInfo?) -> String {
        guard let capacity = info?.designCapacity, capacity > 0 else { return "—" }
        return "\(capacity) mAh"
    }

    private func formatMinutes(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }
}

// MARK: - 英雄卡（第一屏：电量/状态 + 可信估算 + 实时读数）

/// 只读取采样器实时字段的小视图：瓦数每秒变化只失效这一小块，
/// 页面根视图与历史 Chart 不随之重建。
private struct StatusHero: View {
    let sampler: PowerSampler

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            LiveReadoutsRow(sampler: sampler)
        }
        .glassCard(accent: accentColor)
    }

    private var isPluggedIn: Bool { sampler.currentInfo?.externalConnected ?? false }
    private var isFullCharge: Bool { isPluggedIn && sampler.currentLevel >= 100 }
    private var accentColor: Color {
        if isFullCharge || sampler.currentIsCharging { return .bbMint }
        if sampler.currentLevel <= 20 { return .red }
        return .bbBlue
    }

    @ViewBuilder
    private var headline: some View {
        if isFullCharge {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.12)).frame(width: 54, height: 54)
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("电池已充满").font(.system(size: 20, weight: .bold))
                    Text("已连接电源适配器")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(sampler.currentLevel))")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        Text("%").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Text(String(format: "健康度 %.0f%%", sampler.systemHealthPercent))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        } else if sampler.currentIsCharging {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.12)).frame(width: 54, height: 54)
                    Image(systemName: "bolt.fill").font(.system(size: 24)).foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("充电中").font(.system(size: 20, weight: .bold)).foregroundStyle(.green)
                    if remainingToFull > 0 {
                        Text("预计 \(hoursText(remainingToFull)) 后充满")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("计算中…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if sampler.currentLevel >= 80 {
                        Text(sampler.currentLevel >= 95 ? "涓流充电阶段" : "减速充电阶段")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                Spacer()
                levelBadge
            }
        } else {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.bbBlue.opacity(0.12)).frame(width: 54, height: 54)
                    Image(systemName: sampler.currentLevel <= 20 ? "battery.25percent" : "battery.75percent")
                        .font(.system(size: 24))
                        .foregroundStyle(sampler.currentLevel <= 20 ? Color.red : Color.bbBlue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("预估续航").font(.system(size: 11)).foregroundStyle(.secondary)
                    if sampler.cachedDrainRate > 0 {
                        // 考虑5%放电截止保护：实际可用电量为 level - 5
                        let remaining = max(0, sampler.currentLevel - 5) / sampler.cachedDrainRate
                        Text("\(hoursText(remaining))")
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    } else {
                        Text("计算中…")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                levelBadge
            }
        }
    }

    private var levelBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(Int(sampler.currentLevel))")
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            Text("%").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }

    private var remainingToFull: TimeInterval {
        let rate = sampler.cachedChargeRate
        guard rate > 0 else { return 0 }
        return (100 - sampler.currentLevel) / rate * 3600
    }

    private func hoursText(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
}

/// 电池功率 + 系统负载双读数。系统负载标注数据来源：
/// 「系统遥测」「电池侧估算」或「当前不可用」。
private struct LiveReadoutsRow: View {
    let sampler: PowerSampler

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(readoutLabel)
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(String(format: "%.1f W", sampler.currentBatteryPower))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("系统负载")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    HStack(spacing: 5) {
                        if sampler.currentPowerAvailable {
                            Text(String(format: "%.1f W", sampler.currentWattage))
                                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        } else {
                            Text("—")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                        Text(loadSourceText)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(sourceTint)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(sourceTint.opacity(0.1), in: Capsule())
                    }
                }
                Spacer()
            }
        }
    }

    private var readoutLabel: String {
        sampler.currentIsCharging ? "电池充入功率" : "电池放出功率"
    }

    private var loadSourceText: String {
        if sampler.currentPowerAvailable {
            return sampler.currentPowerIsEstimated ? "电池侧估算" : "系统遥测"
        }
        return "当前不可用"
    }

    private var sourceTint: Color {
        if !sampler.currentPowerAvailable { return .secondary }
        return sampler.currentPowerIsEstimated ? .orange : .bbMint
    }
}

// MARK: - 时段趋势 + 摘要（合并为一个区域）

/// 电量趋势与时段摘要的容器。只在 session 模型变化（快照落盘 / 时段切换）时失效；
/// 图表本身再经 EquatableView 隔离，选中态等局部状态不外溢。
private struct SessionTrendCard: View {
    let model: UsageSessionModel

    var body: some View {
        let isCharging = model.isCharging
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(
                    title: model.cardTitle,
                    systemImage: "chart.line.uptrend.xyaxis",
                    tint: isCharging ? .bbMint : .bbBlue
                )
                Spacer()
                if model.summary.durationMin >= 1 {
                    Text(hoursText(model.summary.durationMin))
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if model.points.isEmpty {
                EmptyChartState(
                    title: model.emptyTitle,
                    detail: "电量出现变化后会自动绘制",
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            } else {
                legendRow
                SessionChartPlot(isCharging: isCharging, points: model.points)
                    .equatable()
                summaryRow
            }
        }
        .glassCard(accent: isCharging ? .bbMint : .bbBlue)
    }

    private var legendRow: some View {
        HStack(spacing: 12) {
            ChartLegendItem(
                label: "电量",
                color: model.isCharging ? .bbMint : .bbBlue,
                value: model.points.last.map { "\(Int($0.level))%" }
            )
            if let first = model.points.first, let last = model.points.last {
                let delta = last.level - first.level
                Text(String(format: "%@%.0f%%", delta > 0 ? "+" : "", delta))
                    .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(delta >= 0 ? Color.bbMint : Color.secondary)
            }
            Spacer()
            Text("拖动曲线查看时点")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var summaryRow: some View {
        let s = model.summary
        return HStack(spacing: 16) {
            miniStat(model.isCharging ? "已充入" : "已耗电", value: String(format: "%.0f%%", s.deltaPercent), highlight: true)
            Spacer()
            miniStat("平均电池功率", value: String(format: "%.1fW", s.avgBatteryWatts))
            miniStat("起始", value: "\(Int(s.startLevel))%")
            miniStat("当前", value: "\(Int(s.endLevel))%")
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

    private func hoursText(_ minutes: Double) -> String {
        let total = Int(minutes)
        return "\(total / 60)h \(total % 60)m"
    }
}

/// 输入 Equatable 的隔离子树：points 不变时跳过数百个 Chart marks 的重建。
private struct SessionChartPlot: View, @MainActor Equatable {
    let isCharging: Bool
    let points: [UsageSessionModel.Point]

    @State private var selectedPoint: UsageSessionModel.Point?

    static func == (lhs: SessionChartPlot, rhs: SessionChartPlot) -> Bool {
        lhs.isCharging == rhs.isCharging && lhs.points == rhs.points
    }

    var body: some View {
        let lineColor: Color = isCharging ? .bbMint : .bbBlue
        let windowMin = max(30, ceil((points.last?.relMin ?? 0) / 30) * 30)
        let startTime = points.first?.time ?? Date()
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("时长", p.relMin), y: .value("电量", p.level))
                    .foregroundStyle(lineColor.gradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
                AreaMark(x: .value("时长", p.relMin), yStart: .value("底", 0), yEnd: .value("电量", p.level))
                    .foregroundStyle(LinearGradient(
                        colors: [lineColor.opacity(0.16), lineColor.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            }
            if let latest = points.last {
                PointMark(x: .value("时长", latest.relMin), y: .value("电量", latest.level))
                    .foregroundStyle(lineColor)
                    .symbolSize(28)
            }
            if let selected = selectedPoint {
                RuleMark(x: .value("时长", selected.relMin))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                PointMark(x: .value("时长", selected.relMin), y: .value("电量", selected.level))
                    .foregroundStyle(lineColor)
                    .symbolSize(70)
                    .annotation(position: .top, alignment: .center) {
                        annotation(selected)
                    }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedPoint?.relMin ?? 0 },
            set: { x in
                if let xv = x {
                    selectClosestPoint(x: xv)
                }
            }
        ))
        .chartXAxis {
            AxisMarks(values: strideValues(from: 0, to: windowMin, by: strideStep(windowMin))) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        let absTime = startTime.addingTimeInterval(v * 60)
                        Text(absTime, format: .dateTime.hour().minute())
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let level = value.as(Double.self) {
                        Text("\(Int(level))%")
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quinary)
            }
        }
        .chartXScale(domain: 0...windowMin)
        .chartYScale(domain: yDomain)
        .frame(height: 165)
        .chartSurface()
    }

    private var yDomain: ClosedRange<Double> {
        guard let minimum = points.map(\.level).min(),
              let maximum = points.map(\.level).max() else { return 0...100 }
        let desiredSpan = max(20, maximum - minimum + 12)
        var lower = max(0, floor((minimum - 6) / 5) * 5)
        var upper = min(100, lower + desiredSpan)
        if upper - lower < desiredSpan {
            lower = max(0, upper - desiredSpan)
        }
        upper = min(100, ceil(upper / 5) * 5)
        return lower...max(lower + 5, upper)
    }

    private func strideValues(from: Double, to: Double, by: Double) -> [Double] {
        var result: [Double] = []
        var v = from
        while v <= to + 0.001 {
            result.append(v)
            v += by
        }
        return result
    }

    private func strideStep(_ windowMin: Double) -> Double {
        if windowMin <= 60 { return 10 }
        if windowMin <= 180 { return 30 }
        if windowMin <= 360 { return 60 }
        return 120
    }

    private func selectClosestPoint(x: Double) {
        var best: UsageSessionModel.Point?
        var bestDiff = Double.infinity
        for p in points {
            let diff = abs(p.relMin - x)
            if diff < bestDiff {
                bestDiff = diff
                best = p
            }
        }
        if let b = best {
            selectedPoint = b
        }
    }

    private func annotation(_ selected: UsageSessionModel.Point) -> some View {
        VStack(spacing: 2) {
            Text(selected.time, format: .dateTime.hour().minute())
                .font(.caption2.monospacedDigit())
            Text("\(Int(selected.level))%").font(.caption.bold())
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

// MARK: - 时段分析模型

/// 当前/上次充放电时段的分析结果。由快照通知与时段切换触发重算
/// （UsageTab.reloadSession），View body 只消费结果，不做扫描与统计。
@MainActor
@Observable
final class UsageSessionModel {
    enum SessionKind: Equatable {
        case currentDischarge
        case currentCharge
        case lastCharge
    }

    struct Point: Equatable {
        let relMin: Double
        let level: Double
        let time: Date
    }

    struct Summary: Equatable {
        var startLevel: Double = 0
        var endLevel: Double = 0
        var deltaPercent: Double = 0
        var avgBatteryWatts: Double = 0
        var durationMin: Double = 0
    }

    private(set) var isCharging = false
    private(set) var points: [Point] = []
    private(set) var summary = Summary()

    var cardTitle: String {
        switch kind {
        case .currentDischarge: return "本次耗电趋势"
        case .currentCharge: return "本次充电趋势"
        case .lastCharge: return "上次充电摘要"
        }
    }

    var emptyTitle: String {
        kind == .lastCharge ? "暂无充电记录" : "正在建立电量曲线"
    }

    private(set) var kind: SessionKind = .currentDischarge

    private static let maxPoints = 480

    func reload(snapshots: [BatterySnapshot], kind: SessionKind) {
        self.kind = kind
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        switch kind {
        case .currentDischarge:
            build(from: sorted, isCharging: false, findLastSwitch: true)
        case .currentCharge:
            build(from: sorted, isCharging: true, findLastSwitch: true)
        case .lastCharge:
            buildLastCharge(from: sorted)
        }
    }

    /// 当前时段：找最后一次切到目标状态的点；找不到时回退到第一个同状态点
    private func build(from sorted: [BatterySnapshot], isCharging target: Bool, findLastSwitch: Bool) {
        self.isCharging = target
        var start: Date?
        var prevCharging: Bool?
        for snap in sorted {
            if let prev = prevCharging, prev != snap.isCharging, snap.isCharging == target {
                start = snap.timestamp
            }
            prevCharging = snap.isCharging
        }
        if start == nil {
            start = sorted.first(where: { $0.isCharging == target })?.timestamp
        }
        guard let sessionStart = start else {
            points = []
            summary = Summary()
            return
        }
        accumulate(from: sessionStart, sorted: sorted)
    }

    private func accumulate(from start: Date, sorted: [BatterySnapshot]) {
        let sessionSnaps = sorted.filter { $0.timestamp >= start }
        guard let first = sessionSnaps.first else {
            points = []
            summary = Summary()
            return
        }
        // 只保留电量有变化的点，避免电量不变时往右画水平线；末点始终保留
        let filtered = Self.changedLevelPoints(sessionSnaps)
        points = Self.downsample(filtered).map { snap in
            Point(relMin: snap.timestamp.timeIntervalSince(start) / 60, level: snap.level, time: snap.timestamp)
        }
        summary = Self.makeSummary(sessionSnaps: sessionSnaps, start: start, isCharging: kind != .currentDischarge)
    }

    /// 满电时展示上一次完成的充电时段
    private func buildLastCharge(from sorted: [BatterySnapshot]) {
        isCharging = true
        var chargeStartIndex: Int?
        for i in (1..<sorted.count).reversed() {
            if !sorted[i - 1].isCharging && sorted[i].isCharging {
                chargeStartIndex = i
                break
            }
        }
        if chargeStartIndex == nil && sorted.last?.isCharging == true {
            chargeStartIndex = sorted.firstIndex(where: { $0.isCharging })
        }
        guard let startIdx = chargeStartIndex, startIdx < sorted.count else {
            points = []
            summary = Summary()
            return
        }

        var endIdx = sorted.count - 1
        for i in startIdx..<sorted.count {
            if sorted[i].level >= 100 || (i > startIdx && !sorted[i].isCharging) {
                endIdx = i
                break
            }
        }
        let sessionSnaps = Array(sorted[startIdx...endIdx])
        guard let first = sessionSnaps.first else {
            points = []
            summary = Summary()
            return
        }
        points = Self.downsample(Self.changedLevelPoints(sessionSnaps)).map { snap in
            Point(relMin: snap.timestamp.timeIntervalSince(first.timestamp) / 60, level: snap.level, time: snap.timestamp)
        }
        summary = Self.makeSummary(sessionSnaps: sessionSnaps, start: first.timestamp, isCharging: true)
    }

    /// 只保留电量有变化的点（首点与其后每个新电量值）；末点始终保留
    private static func changedLevelPoints(_ snaps: [BatterySnapshot]) -> [BatterySnapshot] {
        var filtered: [BatterySnapshot] = []
        var lastLevel: Double?
        for snap in snaps {
            if lastLevel == nil || snap.level != lastLevel {
                filtered.append(snap)
                lastLevel = snap.level
            }
        }
        if let last = snaps.last, filtered.last?.id != last.id {
            filtered.append(last)
        }
        return filtered
    }

    private static func makeSummary(sessionSnaps: [BatterySnapshot], start: Date, isCharging: Bool) -> Summary {
        guard let first = sessionSnaps.first, let last = sessionSnaps.last else { return Summary() }
        let delta = isCharging ? last.level - first.level : first.level - last.level
        let watts = sessionSnaps.map(\.batteryPower).filter { $0 > 0 }
        let avg = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)
        return Summary(
            startLevel: first.level,
            endLevel: last.level,
            deltaPercent: delta,
            avgBatteryWatts: avg,
            durationMin: last.timestamp.timeIntervalSince(start) / 60
        )
    }

    /// 曲线点数上限：超出时按均匀步长抽稀并保留末点，防止长时段渲染退化
    private static func downsample(_ snaps: [BatterySnapshot]) -> [BatterySnapshot] {
        guard snaps.count > maxPoints else { return snaps }
        let step = Double(snaps.count) / Double(maxPoints)
        var result: [BatterySnapshot] = []
        var cursor = 0.0
        while Int(cursor) < snaps.count - 1 {
            result.append(snaps[Int(cursor)])
            cursor += step
        }
        if let last = snaps.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }
}
