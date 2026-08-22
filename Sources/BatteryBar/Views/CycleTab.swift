import SwiftUI
import Charts

struct CycleTab: View {
    @State private var cycles: [ChargeCycle] = []
    @State private var lastCycleUpdate: Date = .distantPast
    @State private var selectedCycleDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                summaryCard
                if cycles.count >= 2 { trendCard }
                listCard
            }
            .padding(20)
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
        cycles.isEmpty ? 0 : cycles.map(\.duration).reduce(0, +) / Double(cycles.count)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "循环概览", systemImage: "arrow.triangle.2.circlepath", tint: .green)
            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "arrow.triangle.2.circlepath", tint: .green, value: "\(cycles.count)", unit: "次", label: "循环次数")
                StatTile(icon: "clock.arrow.circlepath", tint: .blue, value: fmt(avgDuration), unit: "", label: "平均续航")
                StatTile(icon: "trophy.fill", tint: .orange, value: fmt(cycles.max(by: { $0.duration < $1.duration })?.duration ?? 0), unit: "", label: "最长循环")
            }
        }
        .glassCard()
    }

    // MARK: - 趋势图

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "续航能力趋势", systemImage: "chart.line.uptrend.xyaxis", tint: .blue)
            Text("每次放电周期时长，变短可能意味着电池老化")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Chart {
                ForEach(cycles, id: \.id) { cycle in
                    AreaMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(
                            LinearGradient(colors: [.accentColor.opacity(0.12), .accentColor.opacity(0)], startPoint: .top, endPoint: .bottom)
                        )
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(Color.accentColor.gradient)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let selected = selectedCycleDate {
                    RuleMark(x: .value("选中", selected))
                        .foregroundStyle(.quaternary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    if let closest = cycles.min(by: { abs($0.startDate.timeIntervalSince(selected)) < abs($1.startDate.timeIntervalSince(selected)) }) {
                        PointMark(x: .value("循环", closest.startDate), y: .value("时长", closest.duration / 3600))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(60)
                            .annotation(position: .top, alignment: .center) {
                                trendTooltip(closest)
                            }
                    }
                }
            }
            .chartXSelection(value: $selectedCycleDate)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.month().day())
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                }
            }
            .chartYAxis {
                AxisMarks {
                    AxisValueLabel()
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.quinary)
                }
            }
            .frame(height: 190)
        }
        .glassCard()
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    // MARK: - 循环记录列表

    private var listCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "循环记录", systemImage: "clock.arrow.circlepath", tint: .teal)
                Text("共 \(cycles.count) 条")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 2)
            }
            if cycles.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.quaternary)
                        Text("暂无循环记录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("完成一次完整的充放电后将自动记录")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 28)
                    Spacer()
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(cycles.reversed(), id: \.id) { cycle in
                        cycleRow(cycle)
                    }
                }
            }
        }
        .glassCard()
    }

    private func cycleRow(_ cycle: ChargeCycle) -> some View {
        HStack(alignment: .center, spacing: 12) {
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
