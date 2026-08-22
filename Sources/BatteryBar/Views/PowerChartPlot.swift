import SwiftUI
import Charts

/// 历史曲线与实时指标隔离。父页面每秒刷新数字时，只要输入快照和显示开关不变，
/// EquatableView 会跳过数百个 Chart marks 的重新构造。
struct PowerChartPlot: View, @MainActor Equatable {
    let snapshots: [BatterySnapshot]
    let timeRange: TimeRange
    let showCPU: Bool
    let showGPU: Bool
    let showDisplay: Bool
    let showDRAM: Bool

    @State private var selectedTime: Date?

    static func == (lhs: PowerChartPlot, rhs: PowerChartPlot) -> Bool {
        lhs.snapshots == rhs.snapshots
            && lhs.timeRange == rhs.timeRange
            && lhs.showCPU == rhs.showCPU
            && lhs.showGPU == rhs.showGPU
            && lhs.showDisplay == rhs.showDisplay
            && lhs.showDRAM == rhs.showDRAM
    }

    var body: some View {
        let yMaximum = powerYMaximum
        Chart {
            ForEach(snapshots, id: \.id) { snap in
                AreaMark(x: .value("时间", snap.timestamp), y: .value("功率", snap.wattage))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.bbAmber.opacity(0.18), Color.bbAmber.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                LineMark(x: .value("时间", snap.timestamp), y: .value("功率", snap.wattage))
                    .foregroundStyle(Color.bbAmber.gradient)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
            }
            if showCPU {
                ForEach(snapshots, id: \.id) { snap in
                    componentLine(snap.timestamp, value: snap.cpuPower, label: "CPU", color: .bbBlue)
                }
            }
            if showGPU {
                ForEach(snapshots, id: \.id) { snap in
                    componentLine(snap.timestamp, value: snap.gpuPower, label: "GPU", color: .bbPurple)
                }
            }
            if showDRAM {
                ForEach(snapshots, id: \.id) { snap in
                    componentLine(snap.timestamp, value: snap.dramPower, label: "内存", color: .teal)
                }
            }
            if showDisplay {
                ForEach(snapshots, id: \.id) { snap in
                    componentLine(snap.timestamp, value: snap.displayPower, label: "显示器", color: .orange)
                }
            }
            if let selectedTime {
                RuleMark(x: .value("选中", selectedTime))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                if let closest = closestSnapshot(to: selectedTime) {
                    PointMark(x: .value("时间", closest.timestamp), y: .value("功率", closest.wattage))
                        .foregroundStyle(Color.bbAmber)
                        .symbolSize(60)
                        .annotation(position: .top, alignment: .center) {
                            tooltip(closest)
                        }
                }
            }
        }
        .chartXSelection(value: $selectedTime)
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisStride.component, count: timeRange.axisStride.count)) {
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let watts = value.as(Double.self) {
                        Text(String(format: "%.0fW", watts))
                            .font(.system(size: 9, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quinary)
            }
        }
        .chartYScale(domain: 0...yMaximum)
        .frame(height: 176)
        .chartSurface()
    }

    @ChartContentBuilder
    private func componentLine(_ timestamp: Date, value: Double, label: String, color: Color) -> some ChartContent {
        LineMark(x: .value("时间", timestamp), y: .value(label, value))
            .foregroundStyle(color)
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func closestSnapshot(to date: Date) -> BatterySnapshot? {
        snapshots.min {
            abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
        }
    }

    private func tooltip(_ snapshot: BatterySnapshot) -> some View {
        VStack(spacing: 2) {
            Text(snapshot.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(String(format: "总 %.1fW", snapshot.wattage))
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            if showCPU { metric("CPU", snapshot.cpuPower, color: .bbBlue) }
            if showGPU { metric("GPU", snapshot.gpuPower, color: .bbPurple) }
            if showDRAM { metric("内存", snapshot.dramPower, color: .teal) }
            if showDisplay { metric("显示器", snapshot.displayPower, color: .orange) }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func metric(_ label: String, _ value: Double, color: Color) -> some View {
        Text(String(format: "%@ %.1fW", label, value))
            .font(.system(size: 9, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
    }

    private var powerYMaximum: Double {
        var values = snapshots.map(\.wattage)
        if showCPU { values.append(contentsOf: snapshots.map(\.cpuPower)) }
        if showGPU { values.append(contentsOf: snapshots.map(\.gpuPower)) }
        if showDRAM { values.append(contentsOf: snapshots.map(\.dramPower)) }
        if showDisplay { values.append(contentsOf: snapshots.map(\.displayPower)) }
        let maximum = max(2, values.max() ?? 2)
        return ceil(maximum * 1.18 / 2) * 2
    }
}
