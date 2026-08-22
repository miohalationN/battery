import SwiftUI
import Charts

struct CycleTab: View {
    @State private var cycles: [ChargeCycle] = []
    @State private var lastCycleUpdate: Date = .distantPast
    @State private var selectedCycleDate: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCards
                if cycles.count >= 2 { trendChart }
                cycleList
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

    private var summaryCards: some View {
        let avgDur = cycles.isEmpty ? 0 : cycles.map(\.duration).reduce(0, +) / Double(cycles.count)
        return HStack(spacing: 12) {
            summaryCard("循环次数", value: "\(cycles.count)", icon: "arrow.triangle.2.circlepath", color: .green)
            summaryCard("平均续航", value: fmt(avgDur), icon: "clock.arrow.circlepath", color: .blue)
            summaryCard("最长循环", value: fmt(cycles.max(by: { $0.duration < $1.duration })?.duration ?? 0), icon: "trophy.fill", color: .yellow)
        }
    }

    private func summaryCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(color)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("续航能力趋势").font(.headline)
                    Text("每次放电周期时长，时长变短可能意味着电池老化")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            Chart {
                ForEach(cycles, id: \.id) { cycle in
                    LineMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(Color.accentColor.gradient)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("循环", cycle.startDate), y: .value("时长", cycle.duration / 3600))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(30)
                }
                if let selected = selectedCycleDate {
                    RuleMark(x: .value("选中", selected))
                        .foregroundStyle(.tertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    if let closest = cycles.min(by: { abs($0.startDate.timeIntervalSince(selected)) < abs($1.startDate.timeIntervalSince(selected)) }) {
                        PointMark(x: .value("循环", closest.startDate), y: .value("时长", closest.duration / 3600))
                            .annotation(position: .top, alignment: .center) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(closest.startDate, format: .dateTime.month().day().hour().minute())
                                        .font(.caption2.monospacedDigit())
                                    Text("\(Int(closest.startLevel))% → \(Int(closest.endLevel))%")
                                        .font(.caption.bold())
                                    Text("时长 \(fmt(closest.duration))")
                                        .font(.caption2.monospacedDigit())
                                    Text(String(format: "平均 %.1fW", closest.averageWattage))
                                        .font(.caption2.monospacedDigit())
                                }
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
            }
            .chartXSelection(value: $selectedCycleDate)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.month().day())
                        .foregroundStyle(.primary)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                        .foregroundStyle(.quaternary)
                }
            }
            .chartYAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(.primary) }
            }
            .chartYAxisLabel("时长（小时）")
            .frame(height: 180)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private var cycleList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("循环记录").font(.headline)
                Spacer()
                Text("共 \(cycles.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if cycles.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("暂无循环记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("完成一次完整的充放电后将自动记录")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 32)
                    Spacer()
                }
            } else {
                ForEach(cycles.reversed(), id: \.id) { cycle in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(cycle.startDate, format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(fmt(cycle.duration))
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        HStack {
                            Text("\(Int(cycle.startLevel))% → \(Int(cycle.endLevel))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("放电 \(String(format: "%.1f", cycle.totalEnergy))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(String(format: "%.1fW", cycle.averageWattage))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    if cycle.id != cycles.first?.id { Divider() }
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private func fmt(_ seconds: TimeInterval) -> String { "\(Int(seconds)/3600)h \((Int(seconds)%3600)/60)m" }
}
