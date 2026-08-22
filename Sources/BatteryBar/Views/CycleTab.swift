import SwiftUI
import Charts

struct CycleTab: View {
    @State private var cycles: [ChargeCycle] = []
    @State private var lastCycleUpdate: Date = .distantPast
    @State private var selectedCycleDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                PageHeader(
                    title: "循环与趋势",
                    subtitle: "观察每次离电周期的续航变化",
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: .bbBlue,
                    badge: "\(validCycles.count) 次记录"
                )
                summaryCard
                if validCycles.count >= 2 { trendCard }
                listCard
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.top, 46)
            .padding(.bottom, BBDesign.pagePadding)
        }
        .onAppear {
            cycles = DataStore.shared.allCycles()
            lastCycleUpdate = Date()
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            let now = Date()
            if now.timeIntervalSince(lastCycleUpdate) > 50 {
                cycles = DataStore.shared.allCycles()
                lastCycleUpdate = now
            }
        }
    }

    // MARK: - 概览

    private var avgDuration: TimeInterval {
        validCycles.isEmpty ? 0 : validCycles.map(\.duration).reduce(0, +) / Double(validCycles.count)
    }

    /// 旧版本曾把充电段误存为放电循环；这些记录会制造反向电量与零耗电曲线，UI 层不再展示。
    private var validCycles: [ChargeCycle] {
        cycles
            .filter { $0.duration >= 300 && $0.startLevel - $0.endLevel >= 1 }
            .sorted { $0.startDate < $1.startDate }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "循环概览", systemImage: "arrow.triangle.2.circlepath", tint: .bbMint)
            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "arrow.triangle.2.circlepath", tint: .bbMint, value: "\(validCycles.count)", unit: "次", label: "有效循环")
                StatTile(icon: "clock.arrow.circlepath", tint: .bbBlue, value: fmt(avgDuration), unit: "", label: "平均续航")
                StatTile(icon: "trophy.fill", tint: .bbAmber, value: fmt(validCycles.max(by: { $0.duration < $1.duration })?.duration ?? 0), unit: "", label: "最长循环")
            }
        }
        .glassCard(accent: .bbMint)
    }

    // MARK: - 趋势图

    private var trendCard: some View {
        let chartCycles = validCycles
        let averageHours = avgDuration / 3600
        let maximumHours = max(1, chartCycles.map { $0.duration / 3600 }.max() ?? 1)
        let yMaximum = ceil(maximumHours * 1.18 * 2) / 2
        let timeSpan = (chartCycles.last?.startDate.timeIntervalSince(chartCycles.first?.startDate ?? Date())) ?? 0
        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "续航能力趋势", systemImage: "chart.line.uptrend.xyaxis", tint: .bbBlue)
                ChartLegendItem(label: "周期时长", color: .bbBlue, value: "平均 \(fmt(avgDuration))")
            }
            HStack {
                Text("按时间排序的有效放电周期；曲线采用单调插值，不制造额外峰谷")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("拖动查看记录")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(chartCycles, id: \.id) { cycle in
                    AreaMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(
                            LinearGradient(colors: [Color.bbBlue.opacity(0.16), Color.bbBlue.opacity(0)], startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(Color.bbBlue.gradient)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(Color.bbBlue)
                        .symbolSize(22)
                }
                RuleMark(y: .value("平均", averageHours))
                    .foregroundStyle(Color.bbBlue.opacity(0.34))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                if let selected = selectedCycleDate {
                    RuleMark(x: .value("选中", selected))
                        .foregroundStyle(.quaternary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    if let closest = chartCycles.min(by: { abs($0.startDate.timeIntervalSince(selected)) < abs($1.startDate.timeIntervalSince(selected)) }) {
                        PointMark(x: .value("循环", closest.startDate), y: .value("时长", closest.duration / 3600))
                            .foregroundStyle(Color.bbBlue)
                            .symbolSize(72)
                            .annotation(position: .top, alignment: .center) {
                                trendTooltip(closest)
                            }
                    }
                }
            }
            .chartXSelection(value: $selectedCycleDate)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            if timeSpan > 86_400 * 2 {
                                Text(date, format: .dateTime.month().day())
                            } else {
                                Text(date, format: .dateTime.hour().minute())
                            }
                        }
                    }
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(String(format: "%.1fh", hours))
                                .font(.system(size: 9, design: .rounded).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.quinary)
                }
            }
            .chartYScale(domain: 0...yMaximum)
            .frame(height: 190)
            .chartSurface()
        }
        .glassCard(accent: .bbBlue)
    }

    /// 悬停数据点提示（玻璃小卡）
    private func trendTooltip(_ closest: ChargeCycle) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(closest.startDate, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text("\(Int(closest.startLevel))% → \(Int(closest.endLevel))%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            HStack(spacing: 8) {
                Text("时长 \(fmt(closest.duration))")
                Text(String(format: "均 %.1fW", closest.averageWattage))
            }
            .font(.system(size: 9, design: .rounded).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    // MARK: - 循环记录列表

    private var listCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "循环记录", systemImage: "clock.arrow.circlepath", tint: .bbTeal)
                Text("共 \(validCycles.count) 条")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
            }
            if validCycles.isEmpty {
                EmptyChartState(
                    title: "暂无有效放电循环",
                    detail: "完成一次超过 1% 的离电使用后会自动记录",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            } else {
                VStack(spacing: 4) {
                    ForEach(validCycles.reversed(), id: \.id) { cycle in
                        cycleRow(cycle)
                    }
                }
            }
        }
        .glassCard(accent: .bbTeal)
    }

    private func cycleRow(_ cycle: ChargeCycle) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.bbTeal)
                .frame(width: 3, height: 34)
            // 起止电量胶囊
            Text("\(Int(cycle.startLevel))% → \(Int(cycle.endLevel))%")
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(cycle.startDate, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                HStack(spacing: 6) {
                    Text("放电 \(String(format: "%.1f", cycle.totalEnergy))%")
                    Text("·")
                    Text(String(format: "均 %.1fW", cycle.averageWattage))
                }
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(fmt(cycle.duration))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fmt(_ seconds: TimeInterval) -> String { "\(Int(seconds)/3600)h \((Int(seconds)%3600)/60)m" }
}
