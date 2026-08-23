import SwiftUI
import Charts

/// 离电记录页：展示本 app 检测到的每次离电使用时段，以及归一化的续航趋势。
///
/// 注意区分：这里的「记录」是一次离电使用时段，不是 Apple 的电池循环次数
/// （CycleCount，在概览页健康指标中展示）。
/// 趋势比较使用可比指标（折算满电续航 = 时长 ÷ 下降幅度 × 100），
/// 只有下降 ≥5% 且持续 ≥15 分钟的记录参与；样本不足时明确显示「数据不足」。
struct CycleTab: View {
    @State private var records: [ChargeCycle] = []
    @State private var normalizedRecords: [OffPowerRecordAnalyzer.NormalizedRecord] = []
    @State private var avgFullChargeHours: Double?
    @State private var selectedRecordDate: Date?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                PageHeader(
                    title: "离电记录",
                    subtitle: "每次离电使用时段与归一化续航趋势",
                    systemImage: "list.bullet.rectangle.fill",
                    tint: .bbBlue,
                    badge: "\(records.count) 条记录"
                )
                summaryCard
                trendCard
                listCard
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.top, 46)
            .padding(.bottom, BBDesign.pagePadding)
        }
        .onAppear {
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batteryCyclesDidChange)) { _ in
            reload()
        }
    }

    /// 重算只在快照通知/onAppear 时进行，body 只做格式化
    private func reload() {
        let cycles = DataStore.shared.allCycles()
        records = OffPowerRecordAnalyzer.displayableRecords(from: cycles)
        normalizedRecords = OffPowerRecordAnalyzer.normalizedRecords(from: cycles)
        avgFullChargeHours = OffPowerRecordAnalyzer.averageFullChargeHours(of: normalizedRecords)
    }

    // MARK: - 概览

    private var longestDuration: TimeInterval {
        records.map(\.duration).max() ?? 0
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "离电记录概览", systemImage: "list.bullet.rectangle.fill", tint: .bbMint)
            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "list.bullet.rectangle", tint: .bbMint, value: "\(records.count)", unit: "条", label: "离电记录")
                StatTile(icon: "battery.100", tint: .bbBlue,
                         value: avgFullChargeHours.map { fmtHours($0 * 3600) } ?? "—", unit: "", label: "折算满电续航")
                StatTile(icon: "clock.arrow.circlepath", tint: .bbAmber,
                         value: records.isEmpty ? "—" : fmtHours(longestDuration), unit: "", label: "最长记录")
            }
        }
        .glassCard(accent: .bbMint)
    }

    // MARK: - 归一化趋势

    private var trendCard: some View {
        let chartRecords = normalizedRecords
        let averageHours = avgFullChargeHours ?? 0
        let maximumHours = max(1, chartRecords.map(\.fullChargeHours).max() ?? 1)
        let yMaximum = ceil(maximumHours * 1.18 * 2) / 2
        let timeSpan = (chartRecords.last?.cycle.startDate.timeIntervalSince(chartRecords.first?.cycle.startDate ?? Date())) ?? 0
        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "续航能力趋势", systemImage: "chart.line.uptrend.xyaxis", tint: .bbBlue)
                ChartLegendItem(label: "折算满电续航", color: .bbBlue, value: avgFullChargeHours.map { "平均 \(fmtHours($0 * 3600))" })
            }
            HStack {
                Text("仅含下降 ≥5% 且持续 ≥15 分钟的记录；折算满电续航 = 时长 ÷ 下降幅度 × 100，不同电量降幅可比较")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("拖动查看记录")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if chartRecords.count < 2 {
                EmptyChartState(
                    title: "数据不足",
                    detail: "完成两次下降 ≥5%、持续 ≥15 分钟的离电使用后生成可比趋势",
                    systemImage: "chart.dots.scatter"
                )
            } else {
                trendChart(chartRecords: chartRecords, averageHours: averageHours, yMaximum: yMaximum, timeSpan: timeSpan)
            }
        }
        .glassCard(accent: .bbBlue)
    }

    @ViewBuilder
    private func trendChart(
        chartRecords: [OffPowerRecordAnalyzer.NormalizedRecord],
        averageHours: Double,
        yMaximum: Double,
        timeSpan: TimeInterval
    ) -> some View {
        Chart {
            ForEach(chartRecords, id: \.cycle.id) { record in
                AreaMark(x: .value("记录", record.cycle.startDate), y: .value("续航", record.fullChargeHours))
                    .foregroundStyle(
                        LinearGradient(colors: [Color.bbBlue.opacity(0.16), Color.bbBlue.opacity(0)], startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.monotone)
                LineMark(x: .value("记录", record.cycle.startDate), y: .value("续航", record.fullChargeHours))
                    .foregroundStyle(Color.bbBlue.gradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("记录", record.cycle.startDate), y: .value("续航", record.fullChargeHours))
                    .foregroundStyle(Color.bbBlue)
                    .symbolSize(22)
            }
            RuleMark(y: .value("平均", averageHours))
                .foregroundStyle(Color.bbBlue.opacity(0.34))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            if let selected = selectedRecordDate {
                RuleMark(x: .value("选中", selected))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                if let closest = chartRecords.min(by: {
                    abs($0.cycle.startDate.timeIntervalSince(selected)) < abs($1.cycle.startDate.timeIntervalSince(selected))
                }) {
                    PointMark(x: .value("记录", closest.cycle.startDate), y: .value("续航", closest.fullChargeHours))
                        .foregroundStyle(Color.bbBlue)
                        .symbolSize(72)
                        .annotation(position: .top, alignment: .center) {
                            trendTooltip(closest)
                        }
                }
            }
        }
        .chartXSelection(value: $selectedRecordDate)
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
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(String(format: "%.1fh", hours))
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
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

    /// 悬停数据点提示
    private func trendTooltip(_ record: OffPowerRecordAnalyzer.NormalizedRecord) -> some View {
        let cycle = record.cycle
        return VStack(alignment: .leading, spacing: 3) {
            Text(cycle.startDate, format: .dateTime.month().day().hour().minute())
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text("\(Int(cycle.startLevel))% → \(Int(cycle.endLevel))%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            HStack(spacing: 8) {
                Text("折算满电 \(fmtHours(record.fullChargeHours * 3600))")
                Text(String(format: "%.1f%%/h", record.percentPerHour))
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

    // MARK: - 记录列表（惰性构造）

    private var listCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "离电时段", systemImage: "clock.arrow.circlepath", tint: .bbTeal)
                Text("共 \(records.count) 条")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
            }
            if records.isEmpty {
                EmptyChartState(
                    title: "暂无离电记录",
                    detail: "完成一次超过 1% 的离电使用后会自动记录",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(records.reversed(), id: \.id) { cycle in
                        recordRow(cycle)
                    }
                }
            }
        }
        .glassCard(accent: .bbTeal)
    }

    private func recordRow(_ cycle: ChargeCycle) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.bbTeal)
                .frame(width: 3, height: 34)
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
                    Text(String(format: "放电 %.1f%%", cycle.totalEnergy))
                    Text("·")
                    Text(String(format: "均 %.1fW", cycle.averageWattage))
                }
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(fmtHours(cycle.duration))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fmtHours(_ seconds: TimeInterval) -> String { "\(Int(seconds) / 3600)h \((Int(seconds) % 3600) / 60)m" }
}
