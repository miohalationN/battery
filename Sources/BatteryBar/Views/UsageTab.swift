import SwiftUI
import Charts

/// 电池概览页。信息架构：现在怎么样 → 为什么 → 详细信息。
///
/// 失效边界：根视图只读低频字段（level / powerSourceState / session 模型）；
/// 温度、电压、电流等易变读数分别在 HealthMetricsGrid 与 BatteryDetailSection
/// 独立观察子视图内消费，不使页面根失效；时段曲线由快照通知驱动的
/// UsageSessionModel 渲染，Chart 为输入 Equatable 的隔离子树。
struct UsageTab: View {
    @Environment(PowerSampler.self) private var sampler
    @State private var session = UsageSessionModel()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    PageHeader(
                        title: "电池概览",
                        subtitle: "续航、健康与当前充放电状态",
                        systemImage: statusIcon,
                        tint: statusColor,
                        badge: "\(Int(sampler.currentLevel))%"
                    )
                    .id(ProfileSupport.topAnchorID)

                    StatusHero(sampler: sampler)

                    HealthMetricsGrid(sampler: sampler)

                    SessionTrendCard(model: session)

                    usageStatsRow

                    BatteryDetailSection(sampler: sampler)
                        .id(ProfileSupport.bottomAnchorID)
                }
                .padding(.horizontal, BBDesign.pagePadding)
                .padding(.top, 46)
                .padding(.bottom, BBDesign.pagePadding)
            }
            .onAppear {
                reloadSession()
                ProfileAutoScroll.run(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
                reloadSession()
            }
            // 时段归属只随插拔/充满切换；重算在通知驱动的一处完成，body 不做任何扫描
            .onChange(of: sessionKind) {
                reloadSession()
            }
        }
    }

    // MARK: - 时段模型（重算只发生在快照变化或时段切换）

    private func reloadSession() {
        session.reload(snapshots: DataStore.shared.allSnapshots(), kind: sessionKind)
    }

    /// 满电状态：必须同时满足"接电"且"电量 >= 100"。
    private var isFullCharge: Bool {
        sampler.currentExternalConnected && sampler.currentLevel >= 100
    }

    private var sessionKind: UsageSessionModel.SessionKind {
        if isFullCharge { return .lastCharge }
        return sampler.powerSourceState == .onBattery ? .currentDischarge : .currentCharge
    }

    private var statusColor: Color {
        switch sampler.powerSourceState {
        case .charging: return .green
        case .onPowerNotCharging: return isFullCharge ? .green : .bbMint
        case .onBattery:
            return sampler.currentLevel <= 20 ? .red : .bbBlue
        }
    }

    private var statusIcon: String {
        switch sampler.powerSourceState {
        case .charging: return "bolt.fill"
        case .onPowerNotCharging: return isFullCharge ? "checkmark.circle.fill" : "powerplug.fill"
        case .onBattery:
            return sampler.currentLevel <= 20 ? "battery.25percent" : "battery.75percent"
        }
    }

    // MARK: - 使用时间统计

    private var usageStatsRow: some View {
        let onBattery = sampler.powerSourceState == .onBattery
        let screenMin = onBattery ? sampler.screenOnTime : sampler.lastScreenOnTime
        let sleepMin = onBattery ? sampler.sleepTime : sampler.lastSleepTime
        let totalMin = screenMin + sleepMin
        let label = onBattery ? "本次使用" : "上次使用"

        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: label, systemImage: "clock.fill", tint: .bbPurple)
                if !onBattery && totalMin == 0 {
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

    private func formatMinutes(_ minutes: Int) -> String { "\(minutes / 60)h \(minutes % 60)m" }
}

// MARK: - 英雄卡（四态：满电接电 / 正在充电 / 接电未充电 / 离电）

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

    private var accentColor: Color {
        switch sampler.powerSourceState {
        case .charging: return .bbMint
        case .onPowerNotCharging: return .bbTeal
        case .onBattery: return sampler.currentLevel <= 20 ? .red : .bbBlue
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch sampler.powerSourceState {
        case .onPowerNotCharging where sampler.currentLevel >= 100:
            fullHero
        case .charging:
            chargingHero
        case .onPowerNotCharging:
            pluggedNotChargingHero
        case .onBattery:
            dischargingHero
        }
    }

    // 满电接电
    private var fullHero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.green.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("电池已充满").font(.system(size: 20, weight: .bold))
                Text("已连接电源适配器 · 满电保持中")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            levelBadge
        }
    }

    // 正在充电
    private var chargingHero: some View {
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
    }

    // 已接电未充电（优化充电暂停 / 80% 上限 / 静置）：不是离电，不给续航预估
    private var pluggedNotChargingHero: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.bbTeal.opacity(0.12)).frame(width: 54, height: 54)
                Image(systemName: "powerplug.fill").font(.system(size: 22)).foregroundStyle(Color.bbTeal)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("已接电，未充电").font(.system(size: 20, weight: .bold))
                Text("充电已暂停或已达上限 · 由电源供电")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            levelBadge
        }
    }

    // 明确离电：才显示续航预估
    private var dischargingHero: some View {
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
        sampler.currentIsCharging ? "电池充入功率" : "电池功率"
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

// MARK: - 健康指标（独立观察子视图）

/// 温度等读数在此视图内消费：变化只失效本块，不波及页面根。
private struct HealthMetricsGrid: View {
    let sampler: PowerSampler

    var body: some View {
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
}

// MARK: - 电池与电源详情（默认折叠，独立观察子视图）

/// 电压/电流等高频诊断在折叠区内独立观察：展开与否都不影响页面根。
private struct BatteryDetailSection: View {
    let sampler: PowerSampler
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            DisclosureGroup(isExpanded: $expanded) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    infoTile("设备名称", value: info?.deviceName ?? "—", icon: "laptopcomputer")
                    infoTile("制造商", value: info?.manufacturer ?? "—", icon: "building.2")
                    infoTile("序列号", value: info?.serialNumber ?? "—", icon: "number")
                    infoTile("设计容量", value: designCapacityString, icon: "doc.text")
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

    private var info: BatteryInfo? { sampler.currentInfo }

    private var designCapacityString: String {
        guard let capacity = info?.designCapacity, capacity > 0 else { return "—" }
        return "\(capacity) mAh"
    }

    private var adapterWattsString: String {
        guard let watts = info?.adapterWatts, watts > 0 else { return "—" }
        return String(format: "%.0f W", watts)
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
                    detail: emptyDetail,
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

    private var emptyDetail: String {
        model.kind == .lastCharge
            ? "完成一次电量上升 ≥1%、时长 ≥5 分钟的充电后生成摘要"
            : "电量出现变化后会自动绘制"
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
