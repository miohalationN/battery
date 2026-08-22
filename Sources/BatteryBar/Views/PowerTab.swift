import SwiftUI
import Charts

struct PowerTab: View {
    @ObservedObject var sampler: PowerSampler
    @State private var snapshots: [BatterySnapshot] = []
    @State private var lastSnapshotUpdate: Date = .distantPast
    @State private var selectedTime: Date?
    @State private var timeRange: TimeRange = .day6
    // 图表曲线显示开关
    @State private var showCPU = false
    @State private var showGPU = false
    @State private var showDisplay = false
    @State private var showDRAM = false
    // Helper 安装中状态
    @State private var isInstallingHelper = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                powerHeroCard
                powerGrid
                componentBreakdownCard
                powerStatsRow
                powerHistoryChart
                helperToggleCard
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("屏幕功耗基于亮度估算；CPU/GPU/内存需 Helper 服务读取。").font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .onAppear {
            snapshots = DataStore.shared.allSnapshots()
            lastSnapshotUpdate = Date()
        }
        .onReceive(sampler.$tick) { _ in
            let now = Date()
            if now.timeIntervalSince(lastSnapshotUpdate) > 60 {
                snapshots = DataStore.shared.allSnapshots()
                lastSnapshotUpdate = now
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

    // MARK: - 顶部英雄卡

    private var powerHeroCard: some View {
        let trend = wattageTrend
        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.12))
                    .frame(width: 54, height: 54)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("系统总功耗")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", sampler.currentWattage))
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    Text("W")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if sampler.helperEnabled {
                VStack(alignment: .trailing, spacing: 8) {
                    heroChip(icon: "cpu", label: "CPU", value: sampler.cpuPower, color: .blue)
                    heroChip(icon: "square.stack.3d.up", label: "GPU", value: sampler.gpuPower, color: .purple)
                }
            }
        }
        .glassCard()
    }

    private func heroChip(icon: String, label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(String(format: "%.1fW", value))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }

    // MARK: - 电学量四格

    private var powerGrid: some View {
        HStack(spacing: BBDesign.itemSpacing) {
            StatTile(icon: "bolt", tint: .blue, value: String(format: "%.0f", sampler.currentVoltage), unit: "mV", label: "电压")
            StatTile(icon: "arrow.left.arrow.right", tint: .green, value: String(format: "%.0f", sampler.currentAmperage), unit: "mA", label: "电流")
            StatTile(icon: "bolt.fill", tint: .yellow, value: String(format: "%.1f", sampler.currentWattage), unit: "W", label: "功率")
            StatTile(icon: "thermometer", tint: .orange,
                     value: sampler.currentTemperature > 0.5 ? String(format: "%.1f", sampler.currentTemperature) : "—",
                     unit: sampler.currentTemperature > 0.5 ? "°C" : "", label: "温度")
        }
    }

    // MARK: - 组件功耗明细

    private var componentBreakdownCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "组件功耗明细", systemImage: "cpu.fill", tint: .purple)

            if sampler.helperEnabled {
                componentBar(label: "CPU", value: sampler.cpuPower, total: sampler.currentWattage, icon: "cpu", color: .blue)
                componentBar(label: "GPU", value: sampler.gpuPower, total: sampler.currentWattage, icon: "square.stack.3d.up", color: .purple)
                if sampler.dramPower > 0 {
                    componentBar(label: "内存", value: sampler.dramPower, total: sampler.currentWattage, icon: "memorychip", color: .teal)
                }
                if sampler.displayPower > 0 {
                    componentBar(label: "显示器", value: sampler.displayPower, total: sampler.currentWattage, icon: "display", color: .orange)
                }
                let other = max(0, sampler.currentWattage - sampler.cpuPower - sampler.gpuPower - sampler.dramPower - sampler.displayPower)
                if other > 0.1 {
                    componentBar(label: "其他", value: other, total: sampler.currentWattage, icon: "ellipsis", color: .gray)
                }
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 9))
                    Text("\"其他\"含主板、SSD、外接设备等无法单独计量的功耗").font(.system(size: 9))
                }
                .foregroundStyle(.tertiary)
            } else {
                // 未开启 Helper：只显示提示，不显示分项（否则"其他"=总功耗毫无意义）
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text("开启下方 Helper 服务后显示 CPU/GPU/内存分项功耗")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: BBDesign.cornerRadiusSmall, style: .continuous))
            }
        }
        .glassCard()
    }

    private func componentBar(label: String, value: Double, total: Double, icon: String, color: Color) -> some View {
        let percentage = total > 0 ? min(100, value / total * 100) : 0
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.1f W · %.0f%%", value, percentage))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: geo.size.width * (percentage / 100))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    // MARK: - 统计三格

    private var powerStatsRow: some View {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let watts = snapshots.filter { $0.timestamp >= cutoff }.map { $0.wattage }
        let avg = watts.isEmpty ? 0 : watts.reduce(0, +) / Double(watts.count)
        let peak = watts.max() ?? 0
        let low = watts.min() ?? 0
        return HStack(spacing: BBDesign.itemSpacing) {
            StatTile(icon: "chart.bar.fill", tint: .blue, value: String(format: "%.1f", avg), unit: "W", label: "平均功耗")
            StatTile(icon: "arrow.up.circle.fill", tint: .red, value: String(format: "%.1f", peak), unit: "W", label: "峰值功耗")
            StatTile(icon: "arrow.down.circle.fill", tint: .green, value: String(format: "%.1f", low), unit: "W", label: "最低功耗")
        }
    }

    // MARK: - 功耗趋势图

    private var powerHistoryChart: some View {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let recent = snapshots.filter { $0.timestamp >= cutoff }
        let hasComponentData = recent.contains { $0.cpuPower > 0 || $0.gpuPower > 0 || $0.dramPower > 0 }

        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "功耗趋势", systemImage: "waveform.path.ecg", tint: .yellow)
                Picker("时间范围", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            // 组件曲线勾选（仅 Helper 开启且有数据时显示）
            if sampler.helperEnabled && hasComponentData {
                HStack(spacing: 8) {
                    toggleChip("CPU", isOn: $showCPU, color: .blue)
                    toggleChip("GPU", isOn: $showGPU, color: .purple)
                    if recent.contains(where: { $0.dramPower > 0 }) {
                        toggleChip("内存", isOn: $showDRAM, color: .teal)
                    }
                    if recent.contains(where: { $0.displayPower > 0 }) {
                        toggleChip("显示器", isOn: $showDisplay, color: .orange)
                    }
                    Spacer()
                }
            }

            if recent.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text("数据采集中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(height: 150)
                    Spacer()
                }
            } else {
                powerChartContent(recent: recent)
            }
        }
        .glassCard()
    }

    private func toggleChip(_ label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn.wrappedValue ? color : Color.primary.opacity(0.15))
                    .frame(width: 6, height: 6)
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn.wrappedValue ? color.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helper 服务开关

    /// Helper 服务开关卡片：默认关闭，开启时弹管理员密码框安装 helper
    @ViewBuilder
    private var helperToggleCard: some View {
        let enabled = sampler.helperEnabled
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14))
                    .foregroundStyle(enabled ? .green : .tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU/GPU 分项功耗")
                        .font(.system(size: 13, weight: .semibold))
                    Text(enabled ? "Helper 已启用 — 正在读取分项功耗" : "默认关闭 — 仅显示系统总功耗")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isInstallingHelper {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            if newValue {
                                isInstallingHelper = true
                                // 安装/卸载走 Task：osascript 阻塞在后台线程执行，主线程保持响应
                                Task { @MainActor in
                                    await sampler.enableHelperInBackground()
                                    isInstallingHelper = false
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
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("Helper 需要更新，请关闭后重新开启").font(.system(size: 10))
                }
                .foregroundStyle(.orange)
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 9))
                Text("开启需要一次管理员密码授权，用于安装读取 powermetrics 的后台服务").font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
        }
        .glassCard()
    }

    // MARK: - 图表内容

    @ViewBuilder
    private func powerChartContent(recent: [BatterySnapshot]) -> some View {
        Chart {
            // 系统总功耗（始终显示，粗主线 + 面积）
            ForEach(recent, id: \.id) { snap in
                AreaMark(x: .value("时间", snap.timestamp), y: .value("功率", snap.wattage))
                    .foregroundStyle(
                        LinearGradient(colors: [.yellow.opacity(0.14), .yellow.opacity(0)], startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("时间", snap.timestamp), y: .value("功率", snap.wattage))
                    .foregroundStyle(Color.yellow.gradient)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            // CPU
            if showCPU {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("CPU", snap.cpuPower))
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            // GPU
            if showGPU {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("GPU", snap.gpuPower))
                        .foregroundStyle(.purple)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            // 内存
            if showDRAM {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("内存", snap.dramPower))
                        .foregroundStyle(.teal)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            // 显示器
            if showDisplay {
                ForEach(recent, id: \.id) { snap in
                    LineMark(x: .value("时间", snap.timestamp), y: .value("显示器", snap.displayPower))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            if let selected = selectedTime {
                RuleMark(x: .value("选中", selected))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                if let closest = recent.min(by: { abs($0.timestamp.timeIntervalSince(selected)) < abs($1.timestamp.timeIntervalSince(selected)) }) {
                    PointMark(x: .value("时间", closest.timestamp), y: .value("功率", closest.wattage))
                        .foregroundStyle(.yellow)
                        .symbolSize(60)
                        .annotation(position: .top, alignment: .center) {
                            VStack(spacing: 2) {
                                Text(closest.timestamp, format: .dateTime.hour().minute())
                                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "总 %.1fW", closest.wattage))
                                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                if showCPU { Text(String(format: "CPU %.1fW", closest.cpuPower)).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.blue) }
                                if showGPU { Text(String(format: "GPU %.1fW", closest.gpuPower)).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.purple) }
                                if showDRAM { Text(String(format: "内存 %.1fW", closest.dramPower)).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.teal) }
                                if showDisplay { Text(String(format: "显示器 %.1fW", closest.displayPower)).font(.system(size: 9, design: .rounded).monospacedDigit()).foregroundStyle(.orange) }
                            }
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
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
            AxisMarks {
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.quinary)
            }
        }
        .chartYAxisLabel("W")
        .frame(height: 150)
    }
}
