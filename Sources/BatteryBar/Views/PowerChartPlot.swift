import SwiftUI
import Charts

/// 趋势图数据点：来自 v5 分钟聚合。
/// `breakBefore` 标记与上一点之间存在缺口（分钟缺失或覆盖率未达标），
/// 渲染时在此断开连线，绝不跨缺口插值。
struct TrendPoint: Equatable {
    let time: Date
    let value: Double
    /// tooltip 附加量（如该窗口的温度最大值）
    let maximum: Double?
    /// 该点所属窗口的覆盖率（tooltip 展示）
    let coverage: Double?
    let breakBefore: Bool

    init(time: Date, value: Double, maximum: Double? = nil, coverage: Double? = nil, breakBefore: Bool = false) {
        self.time = time
        self.value = value
        self.maximum = maximum
        self.coverage = coverage
        self.breakBefore = breakBefore
    }
}

/// 历史趋势曲线与实时指标隔离。父页面刷新数字时，只要输入点不变，
/// EquatableView 会跳过全部 Chart marks 的重新构造。
/// 曲线口径：v5 分钟聚合的 systemPowerAverage / temperatureAverage；
/// 覆盖率不足的分钟留缺口，不外推、不插值。
struct TrendChartPlot: View, @MainActor Equatable {
    let points: [TrendPoint]
    let timeRange: TimeRange
    let unit: String
    let tintColor: Color
    var isTemperature = false

    @State private var selectedTime: Date?

    static func == (lhs: TrendChartPlot, rhs: TrendChartPlot) -> Bool {
        lhs.points == rhs.points && lhs.timeRange == rhs.timeRange
            && lhs.unit == rhs.unit && lhs.tintColor == rhs.tintColor
            && lhs.isTemperature == rhs.isTemperature
    }

    /// 按 breakBefore 切分成连续段；每段独立绘制，段间自然留缺口
    private var segments: [[TrendPoint]] {
        var result: [[TrendPoint]] = []
        var current: [TrendPoint] = []
        for point in points {
            if point.breakBefore, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        Chart {
            // 每个连续段一个独立 ForEach：Charts 会把同组 LineMark/AreaMark 连成一体，
            // 段与段之间自然留缺口，绝不跨缺口插值。
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                ForEach(Array(segment.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("时间", point.time), y: .value("值", point.value))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tintColor.opacity(0.16), tintColor.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("时间", point.time), y: .value("值", point.value))
                        .foregroundStyle(tintColor.gradient)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
                }
            }
            if let selectedTime, let closest = closestPoint(to: selectedTime) {
                RuleMark(x: .value("选中", selectedTime))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                PointMark(x: .value("时间", closest.time), y: .value("值", closest.value))
                    .foregroundStyle(tintColor)
                    .symbolSize(60)
                    .annotation(position: .top, alignment: .center) {
                        tooltip(closest)
                    }
            }
        }
        .chartXSelection(value: $selectedTime)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisStride.component, count: timeRange.axisStride.count)) {
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yLabel(number))
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
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

    private func yLabel(_ number: Double) -> String {
        isTemperature ? String(format: "%.0f°", number) : String(format: "%.0f%@", number, unit)
    }

    private func closestPoint(to date: Date) -> TrendPoint? {
        points.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
    }

    private func tooltip(_ point: TrendPoint) -> some View {
        VStack(spacing: 2) {
            Text(point.time, format: .dateTime.hour().minute())
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(isTemperature
                 ? String(format: "%.1f °C", point.value)
                 : String(format: "%.1f%@", point.value, unit))
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
            if isTemperature, let maximum = point.maximum {
                Text(String(format: "峰值 %.1f °C", maximum))
                    .font(.system(size: 8.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.orange)
            }
            if let coverage = point.coverage {
                Text(String(format: "覆盖 %.0f%%", coverage * 100))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private var yMaximum: Double {
        let maximum = max(2, points.map(\.value).max() ?? 2)
        return ceil(maximum * 1.18 / 2) * 2
    }

    /// 选中的范围始终对应真实墙上时间，而不是被现有少量样本自动撑满。
    /// 例如刚安装 5 分钟时选择“6 小时”，曲线只占最右侧 5 分钟，避免误导。
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        let end = max(now, points.last?.time ?? now)
        return timeRange.domain(endingAt: end)
    }
}
