import SwiftUI
import Charts

/// 历史曲线与实时指标隔离。父页面刷新数字时，只要输入快照不变，
/// EquatableView 会跳过数百个 Chart marks 的重新构造。
/// 曲线口径：系统负载。调用方已过滤掉 systemPowerAvailable == false 的快照
/// （v1 充电快照的 wattage 是电池充电功率，不进入负载曲线）。
struct PowerChartPlot: View, @MainActor Equatable {
    let snapshots: [BatterySnapshot]
    let timeRange: TimeRange

    @State private var selectedTime: Date?

    static func == (lhs: PowerChartPlot, rhs: PowerChartPlot) -> Bool {
        lhs.snapshots == rhs.snapshots && lhs.timeRange == rhs.timeRange
    }

    var body: some View {
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
            Text(String(format: "负载 %.1fW", snapshot.wattage))
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            if snapshot.systemPowerIsEstimated {
                Text("电池侧估算")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            if snapshot.cpuPower > 0 {
                metric("CPU", snapshot.cpuPower, color: .bbBlue)
            }
            if snapshot.gpuPower > 0 {
                metric("GPU", snapshot.gpuPower, color: .bbPurple)
            }
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

    private var yMaximum: Double {
        let maximum = max(2, snapshots.map(\.wattage).max() ?? 2)
        return ceil(maximum * 1.18 / 2) * 2
    }
}
