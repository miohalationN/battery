import SwiftUI
import Charts
import Observation

/// PowerTab 的视图状态模型（@Observable 说明见 CycleTabModel）
@Observable
final class PowerTabModel {
    var snapshots: [BatterySnapshot] = []
    var lastSnapshotUpdate: Date = .distantPast
    var selectedTime: Date?
    var timeRange: TimeRange = .day6
    // 图表曲线显示开关
    var showCPU = false
    var showGPU = false
    var showDisplay = false
    var showDRAM = false
    // Helper 安装中状态
    var isInstallingHelper = false
}

struct PowerTab: View {
    @ObservedObject var sampler: PowerSampler
    @Bindable var model: PowerTabModel

    // 读侧透传：body 内沿用原属性名，改动面最小
    private var snapshots: [BatterySnapshot] { model.snapshots }
    private var timeRange: TimeRange { model.timeRange }
    private var showCPU: Bool { model.showCPU }
    private var showGPU: Bool { model.showGPU }
    private var showDisplay: Bool { model.showDisplay }
    private var showDRAM: Bool { model.showDRAM }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                powerHeroCard
                powerGrid
                componentBreakdownCard
                powerStatsRow
                powerHistoryChart
                helperToggleCard
                HStack {
                    Image(systemName: "info.circle").font(.caption)
                    Text("屏幕功耗基于亮度估算；CPU/GPU/内存需 Helper 服务读取。").font(.caption)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .onAppear {
            model.snapshots = DataStore.shared.allSnapshots()
            model.lastSnapshotUpdate = Date()
        }
        .onReceive(sampler.$tick) { _ in
            let now = Date()
            if now.timeIntervalSince(model.lastSnapshotUpdate) > 60 {
                model.snapshots = DataStore.shared.allSnapshots()
                model.lastSnapshotUpdate = now
            }
        }
    }

    private var wattageTrend: (arrow: String, color: Color) {
        guard snapshots.count >= 2 else { return ("minus", .secondary) }
        let recent = Array(snapshots.suffix(6))
        guard let first = recent.first, let last = recent.last else { return ("minus", .secondary) }
        let delta = last.wattage - first.wattage
        if delta > 0.2 { return ("arrow.up", .red) }
        if delta < -0.2 { return ("arrow.down", .green) }
        return ("minus", .secondary)
    }

    private var powerHeroCard: some View {
        let trend = wattageTrend
        return HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.yellow.opacity(0.12)).frame(width: 60, height: 60)
                Image(systemName: "bolt.fill").font(.system(size: 24)).foregroundStyle(.yellow)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("系统总功耗").font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: trend.arrow).font(.caption).foregroundStyle(trend.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", sampler.currentWattage))
                        .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    Text("W").font(.title3).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if sampler.helperEnabled {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu").font(.caption2).foregroundStyle(.blue)
                        Text(String(format: "%.1fW", sampler.cpuPower)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up").font(.caption2).foregroundStyle(.purple)
                        Text(String(format: "%.1fW", sampler.gpuPower)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
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

    private var powerGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            powerTile("电压", value: String(format: "%.0f", sampler.currentVoltage), unit: "mV", icon: "bolt", color: .blue)
            powerTile("电流", value: String(format: "%.0f", sampler.currentAmperage), unit: "mA", icon: "arrow.left.arrow.right", color: .green)
            powerTile("功率", value: String(format: "%.1f", sampler.currentWattage), unit: "W", icon: "bolt.fill", color: .yellow)
            powerTile("温度", value: sampler.currentTemperature > 0.5 ? String(format: "%.1f", sampler.currentTemperature) : "—", unit: sampler.currentTemperature > 0.5 ? "°C" : "", icon: "thermometer", color: .orange)
        }
    }

    private func powerTile(_ label: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private var componentBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("组件功耗明细").font(.subheadline.bold())

            if sampler.helperEnabled {
                // CPU
                componentBar(label: "CPU", value: sampler.cpuPower, total: sampler.currentWattage, icon: "cpu", color: .blue)
                // GPU
                componentBar(label: "GPU", value: sampler.gpuPower, total: sampler.currentWattage, icon: "square.stack.3d.up", color: .purple)
                // 内存
                if sampler.dramPower > 0 {
                    componentBar(label: "内存", value: sampler.dramPower, total: sampler.currentWattage, icon: "memorychip", color: .teal)
                }
                // 显示器（不依赖 Helper）
                if sampler.displayPower > 0 {
                    componentBar(label: "显示器", value: sampler.displayPower, total: sampler.currentWattage, icon: "display", color: .orange)
                }
                // 其他（总功耗 - 各项，含外设/主板/SSD等）
                let other = max(0, sampler.currentWattage - sampler.cpuPower - sampler.gpuPower - sampler.dramPower - sampler.displayPower)
                if other > 0.1 {
                    componentBar(label: "其他", value: other, total: sampler.currentWattage, icon: "ellipsis", color: .gray)
                }
                // 其他说明
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.caption2)
                    Text("\"其他\"含主板、SSD、外接设备等无法单独计量的功耗").font(.caption2)
                }
                .foregroundStyle(.tertiary)
            } else {
                // 未开启 Helper：只显示提示，不显示分项（否则"其他"=总功耗毫无意义）
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption)
                    Text("开启下方 Helper 服务后显示 CPU/GPU/内存分项功耗").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private func componentBar(label: String, value: Double, total: Double, icon: String, color: Color) -> some View {
        let percentage = total > 0 ? min(100, value / total * 100) : 0
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color).frame(width: 20)
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f W (%.0f%%)", value, percentage))
                    .font(.caption.monospacedDigit())
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color)
                                .frame(width: geo.size.width * (percentage / 100))
                        }
                }
                .frame(height: 6)
            }
        }
    }

    private var powerStatsRow: some View {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let watts = snapshots.filter { $0.timestamp >= cutoff }.map { $0.wattage }
        let avg = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)
        let peak = watts.max() ?? 0
        let low = watts.min() ?? 0
        return HStack(spacing: 10) {
            statCard("平均功耗", value: String(format: "%.1fW", avg), icon: "chart.bar.fill", color: .blue)
            statCard("峰值功耗", value: String(format: "%.1fW", peak), icon: "arrow.up.circle.fill", color: .red)
            statCard("最低功耗", value: String(format: "%.1fW", low), icon: "arrow.down.circle.fill", color: .green)
        }
    }

    private func statCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
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

    private var powerHistoryChart: some View {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let recent = snapshots.filter { $0.timestamp >= cutoff }
        let hasComponentData = recent.contains { $0.cpuPower > 0 || $0.gpuPower > 0 || $0.dramPower > 0 }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("功耗趋势")
                    .font(.subheadline.bold())
                    .padding(.top, 4)
                Spacer()
                Picker("时间范围", selection: $model.timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            // 组件曲线勾选（仅 Helper 开启且有数据时显示）
            if sampler.helperEnabled && hasComponentData {
                HStack(spacing: 12) {
                    toggleChip("CPU", isOn: $model.showCPU, color: .blue)
                    toggleChip("GPU", isOn: $model.showGPU, color: .purple)
                    if recent.contains(where: { $0.dramPower > 0 }) {
                        toggleChip("内存", isOn: $model.showDRAM, color: .teal)
                    }
                    if recent.contains(where: { $0.displayPower > 0 }) {
                        toggleChip("显示器", isOn: $model.showDisplay, color: .orange)
                    }
                    Spacer()
                }
            }

            if recent.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "bolt.slash").font(.title2).foregroundStyle(.tertiary)
                        Text("数据采集中...").font(.caption).foregroundStyle(.secondary)
                    }.frame(height: 160)
                    Spacer()
                }
            } else {
                powerChartContent(recent: recent)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    private func toggleChip(_ label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10))
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(isOn.wrappedValue ? color : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn.wrappedValue ? color.opacity(0.12) : Color.gray.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    /// Helper 服务开关卡片：默认关闭，开启时弹管理员密码框安装 helper
    @ViewBuilder
    private var helperToggleCard: some View {
        let enabled = sampler.helperEnabled
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 16))
                    .foregroundStyle(enabled ? .green : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU/GPU 分项功耗")
                        .font(.system(size: 14, weight: .semibold))
                    Text(enabled ? "Helper 已启用 — 正在读取分项功耗" : "默认关闭 — 仅显示系统总功耗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isInstallingHelper {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            if newValue {
                                model.isInstallingHelper = true
                                // 安装/卸载走 Task：osascript 阻塞在后台线程执行，主线程保持响应
                                Task { @MainActor in
                                    await sampler.enableHelperInBackground()
                                    model.isInstallingHelper = false
                                }
                            } else {
                                Task { @MainActor in
                                    await sampler.disableHelperInBackground()
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            if enabled && sampler.helperNeedsUpdate {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text("Helper 需要更新，请关闭后重新开启").font(.caption2)
                }
                .foregroundStyle(.orange)
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.caption2)
                Text("开启需要一次管理员密码授权，用于安装读取 powermetrics 的后台服务").font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.04), radius: 3, y: 2)
        }
    }

    @ViewBuilder
    private func powerChartContent(recent: [BatterySnapshot]) -> some View {
        Chart {
            // 系统总功耗（始终显示）
            ForEach(recent, id: \.id) { snap in
                LineMark(x: .value("时间", snap.timestamp), y: .value("功率", snap.wattage))
                    .foregroundStyle(Color.yellow)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // CPU
            if showCPU {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("CPU", snap.cpuPower))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // GPU
            if showGPU {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("GPU", snap.gpuPower))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // 内存
            if showDRAM {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("内存", snap.dramPower))
                        .foregroundStyle(.teal)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // 显示器
            if showDisplay {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("显示器", snap.displayPower))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let selected = model.selectedTime {
                RuleMark(x: .value("选中", selected))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                if let closest = recent.min(by: { abs($0.timestamp.timeIntervalSince(selected)) < abs($1.timestamp.timeIntervalSince(selected)) }) {
                    PointMark(x: .value("时间", closest.timestamp), y: .value("功率", closest.wattage))
                        .annotation(position: .top, alignment: .center) {
                            VStack(spacing: 2) {
                                Text(closest.timestamp, format: .dateTime.hour().minute())
                                    .font(.caption2.monospacedDigit())
                                Text(String(format: "总 %.1fW", closest.wattage))
                                    .font(.caption.bold())
                                if showCPU { Text(String(format: "CPU %.1fW", closest.cpuPower)).font(.caption2.monospacedDigit()).foregroundStyle(.blue) }
                                if showGPU { Text(String(format: "GPU %.1fW", closest.gpuPower)).font(.caption2.monospacedDigit()).foregroundStyle(.purple) }
                                if showDRAM { Text(String(format: "内存 %.1fW", closest.dramPower)).font(.caption2.monospacedDigit()).foregroundStyle(.teal) }
                                if showDisplay { Text(String(format: "显示器 %.1fW", closest.displayPower)).font(.caption2.monospacedDigit()).foregroundStyle(.orange) }
                            }
                            .padding(6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        }
                }
            }
        }
        .chartXSelection(value: $model.selectedTime)
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisStride.component, count: timeRange.axisStride.count)) {
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(.primary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks { AxisValueLabel().foregroundStyle(.primary) }
        }
        .chartYAxisLabel("功耗（W）")
        .frame(height: 160)
    }
}
