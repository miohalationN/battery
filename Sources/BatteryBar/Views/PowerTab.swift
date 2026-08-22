import SwiftUI
import Charts

private struct PowerRangeStats {
    var average: Double = 0
    var peak: Double = 0
    var low: Double = 0
}

struct PowerTab: View {
    @EnvironmentObject var sampler: PowerSampler
    @State private var snapshots: [BatterySnapshot] = []
    @State private var rangeSnapshots: [BatterySnapshot] = []
    @State private var chartSnapshots: [BatterySnapshot] = []
    @State private var rangeStats = PowerRangeStats()
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
                PageHeader(
                    title: "功耗分析",
                    subtitle: "总功率、组件占比与历史波动",
                    systemImage: "waveform.path.ecg",
                    tint: .bbAmber,
                    badge: String(format: "%.1f W", sampler.currentWattage)
                )
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
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.top, 46)
            .padding(.bottom, BBDesign.pagePadding)
        }
        .onAppear {
            reloadSnapshots()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
            reloadSnapshots()
        }
        .onChange(of: timeRange) {
            rebuildRangeData(from: snapshots)
        }
    }

    private func reloadSnapshots() {
        let loaded = DataStore.shared.allSnapshots()
        snapshots = loaded
        rebuildRangeData(from: loaded)
    }

    /// 只在快照真正变化或用户切换范围时做 O(n) 过滤/统计/降采样，
    /// 实时功率每秒变化不再重复扫描整天历史数据。
    private func rebuildRangeData(from source: [BatterySnapshot]) {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let filtered = source.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        rangeSnapshots = filtered
        chartSnapshots = ChartDownsampler.powerSnapshots(filtered, maxPoints: 240)

        let watts = filtered.lazy.filter { $0.wattage > 0.05 }.map(\.wattage)
        var count = 0
        var sum = 0.0
        var peak = 0.0
        var low = Double.greatestFiniteMagnitude
        for wattage in watts {
            count += 1
            sum += wattage
            peak = max(peak, wattage)
            low = min(low, wattage)
        }
        rangeStats = PowerRangeStats(
            average: count > 0 ? sum / Double(count) : 0,
            peak: peak,
            low: count > 0 ? low : 0
        )
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
                    .fill(Color.bbAmber.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.bbAmber)
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
                    Image(systemName: trend.arrow)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(trend.color)
                }
            }
            Spacer()
            if sampler.helperEnabled {
                VStack(alignment: .trailing, spacing: 8) {
                    heroChip(icon: "cpu", label: "CPU", value: sampler.cpuPower, color: .bbBlue)
                    heroChip(icon: "square.stack.3d.up", label: "GPU", value: sampler.gpuPower, color: .bbPurple)
                }
            }
        }
        .glassCard(accent: .bbAmber)
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
            StatTile(icon: "bolt", tint: .bbBlue, value: String(format: "%.0f", sampler.currentVoltage), unit: "mV", label: "电压")
            StatTile(icon: "arrow.left.arrow.right", tint: .bbMint, value: String(format: "%.0f", sampler.currentAmperage), unit: "mA", label: "电流")
            StatTile(icon: "bolt.fill", tint: .bbAmber, value: String(format: "%.1f", sampler.currentWattage), unit: "W", label: "功率")
            StatTile(icon: "thermometer", tint: .orange,
                     value: sampler.currentTemperature > 0.5 ? String(format: "%.1f", sampler.currentTemperature) : "—",
                     unit: sampler.currentTemperature > 0.5 ? "°C" : "", label: "温度")
        }
    }

    // MARK: - 组件功耗明细

    private var componentBreakdownCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "组件功耗明细", systemImage: "cpu.fill", tint: .bbPurple)

            if sampler.helperEnabled {
                componentBar(label: "CPU", value: sampler.cpuPower, total: sampler.currentWattage, icon: "cpu", color: .bbBlue)
                componentBar(label: "GPU", value: sampler.gpuPower, total: sampler.currentWattage, icon: "square.stack.3d.up", color: .bbPurple)
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
        .glassCard(accent: .bbPurple)
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
        return HStack(spacing: BBDesign.itemSpacing) {
            StatTile(icon: "chart.bar.fill", tint: .bbBlue, value: String(format: "%.1f", rangeStats.average), unit: "W", label: "平均功耗")
            StatTile(icon: "arrow.up.circle.fill", tint: .red, value: String(format: "%.1f", rangeStats.peak), unit: "W", label: "峰值功耗")
            StatTile(icon: "arrow.down.circle.fill", tint: .green, value: String(format: "%.1f", rangeStats.low), unit: "W", label: "最低功耗")
        }
    }

    // MARK: - 功耗趋势图

    private var powerHistoryChart: some View {
        let hasComponentData = rangeSnapshots.contains { $0.cpuPower > 0 || $0.gpuPower > 0 || $0.dramPower > 0 }

        return VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "功耗趋势", systemImage: "waveform.path.ecg", tint: .bbAmber)
                Picker("时间范围", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            HStack(spacing: 13) {
                ChartLegendItem(
                    label: "系统总功耗",
                    color: .bbAmber,
                    value: rangeSnapshots.last.map { String(format: "%.1fW", $0.wattage) }
                )
                Spacer()
                Text("拖动曲线查看采样点")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            // 组件曲线勾选（仅 Helper 开启且有数据时显示）
            if sampler.helperEnabled && hasComponentData {
                HStack(spacing: 8) {
                    toggleChip("CPU", isOn: $showCPU, color: .bbBlue)
                    toggleChip("GPU", isOn: $showGPU, color: .bbPurple)
                    if rangeSnapshots.contains(where: { $0.dramPower > 0 }) {
                        toggleChip("内存", isOn: $showDRAM, color: .teal)
                    }
                    if rangeSnapshots.contains(where: { $0.displayPower > 0 }) {
                        toggleChip("显示器", isOn: $showDisplay, color: .orange)
                    }
                    Spacer()
                }
            }

            if chartSnapshots.isEmpty {
                EmptyChartState(
                    title: "正在建立功耗趋势",
                    detail: "采样数据将在这里持续更新",
                    systemImage: "bolt.slash"
                )
            } else {
                PowerChartPlot(
                    snapshots: chartSnapshots,
                    timeRange: timeRange,
                    showCPU: showCPU,
                    showGPU: showGPU,
                    showDisplay: showDisplay,
                    showDRAM: showDRAM
                )
                .equatable()
            }
        }
        .glassCard(accent: .bbAmber)
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
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
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
        .glassCard(accent: enabled ? .bbMint : .clear)
    }

}
