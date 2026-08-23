import SwiftUI
import Charts

private struct PowerRangeStats {
    var average: Double = 0
    var peak: Double = 0
    var low: Double = 0
    var sampleCount: Int = 0
    var coverage: TimeInterval = 0
}

/// 功耗页信息架构：当前负载 → 构成 → 历史趋势 → 数据来源 → 高级采样。
///
/// 失效边界：页面根视图只持有历史状态（快照、时间范围、Helper 开关等低频字段），
/// 每秒变化的系统负载/电池功率/组件读数全部收进独立小视图，历史 Chart 经
/// EquatableView 与输入绑定，不被实时值带着重建。
struct PowerTab: View {
    @Environment(PowerSampler.self) private var sampler
    @State private var snapshots: [BatterySnapshot] = []
    @State private var chartSnapshots: [BatterySnapshot] = []
    @State private var rangeStats = PowerRangeStats()
    @State private var timeRange: TimeRange = .hour1
    // Helper 安装中状态
    @State private var isInstallingHelper = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                    PageHeader(
                        title: "功耗分析",
                        subtitle: "当前负载、组件构成与历史波动",
                        systemImage: "waveform.path.ecg",
                        tint: .bbAmber
                    )
                    .id(ProfileSupport.topAnchorID)
                    PowerLoadHero(sampler: sampler)
                    ComponentBreakdownCard(sampler: sampler)
                    historyCard
                    PowerDiagnosticsSection(sampler: sampler)
                    dataSourceFootnote
                    AdvancedSamplingCard(sampler: sampler, isInstallingHelper: $isInstallingHelper)
                        .id(ProfileSupport.bottomAnchorID)
                }
                .padding(.horizontal, BBDesign.pagePadding)
                .padding(.top, 46)
                .padding(.bottom, BBDesign.pagePadding)
            }
            .onAppear {
                reloadSnapshots()
                ProfileAutoScroll.run(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
                reloadSnapshots()
            }
            .onChange(of: timeRange) {
                rebuildRangeData(from: snapshots)
            }
        }
    }

    private func reloadSnapshots() {
        let loaded = DataStore.shared.allSnapshots()
        snapshots = loaded
        rebuildRangeData(from: loaded)
    }

    /// 只在快照真正变化或用户切换范围时做 O(n) 过滤/统计/降采样。
    /// 系统负载统计与曲线只使用 `trustedSystemLoad` 非空的快照：
    /// - 实测遥测（estimated=false）无论电源状态都保留；
    /// - 估算负载只在明确离电（externalConnected == false）时保留；
    /// - 来源未知（v1/v2 旧数据）的估算点——包括历史上"接电未充电被误标
    ///   为可用离电负载"的污染点——保守排除，不再拉低平均/制造假谷底。
    private func rebuildRangeData(from source: [BatterySnapshot]) {
        let cutoff = Date().addingTimeInterval(-timeRange.hours * 3600)
        let filtered = source
            .filter { $0.timestamp >= cutoff }
            .filter { $0.trustedSystemLoad != nil }
            .sorted { $0.timestamp < $1.timestamp }
        chartSnapshots = ChartDownsampler.powerSnapshots(filtered, maxPoints: 240)

        var count = 0
        var sum = 0.0
        var peak = 0.0
        var low = Double.greatestFiniteMagnitude
        for snap in filtered where snap.wattage > 0.05 {
            count += 1
            sum += snap.wattage
            peak = max(peak, snap.wattage)
            low = min(low, snap.wattage)
        }
        rangeStats = PowerRangeStats(
            average: count > 0 ? sum / Double(count) : 0,
            peak: count > 0 ? peak : 0,
            low: count > 0 ? low : 0,
            sampleCount: filtered.count,
            coverage: max(0, (filtered.last?.timestamp.timeIntervalSince(filtered.first?.timestamp ?? Date())) ?? 0)
        )
    }

    // MARK: - 历史趋势

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack {
                SectionHeader(title: "系统负载趋势", systemImage: "waveform.path.ecg", tint: .bbAmber)
                Picker("时间范围", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
            }

            HStack(spacing: BBDesign.itemSpacing) {
                StatTile(icon: "chart.bar.fill", tint: .bbBlue, value: String(format: "%.1f", rangeStats.average), unit: "W", label: "平均负载")
                StatTile(icon: "arrow.up.circle.fill", tint: .red, value: String(format: "%.1f", rangeStats.peak), unit: "W", label: "峰值")
                StatTile(icon: "arrow.down.circle.fill", tint: .green, value: String(format: "%.1f", rangeStats.low), unit: "W", label: "最低")
            }

            HStack(spacing: 13) {
                ChartLegendItem(
                    label: "系统负载",
                    color: .bbAmber,
                    value: chartSnapshots.last.map { String(format: "%.1fW", $0.wattage) }
                )
                Spacer()
                Text(coverageText)
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if chartSnapshots.isEmpty {
                EmptyChartState(
                    title: "正在建立系统负载趋势",
                    detail: "有可用负载数据后这里会持续更新",
                    systemImage: "bolt.slash"
                )
            } else {
                PowerChartPlot(snapshots: chartSnapshots, timeRange: timeRange)
                    .equatable()
            }
        }
        .glassCard(accent: .bbAmber)
    }

    private var coverageText: String {
        guard rangeStats.sampleCount > 1 else {
            return rangeStats.sampleCount == 1 ? "1 个有效点 · 正在采集" : "尚无有效点"
        }
        let minutes = max(1, Int(rangeStats.coverage / 60))
        let span = minutes < 60
            ? "\(minutes) 分钟"
            : String(format: "%.1f 小时", Double(minutes) / 60)
        return "\(rangeStats.sampleCount) 个有效点 · 覆盖 \(span)"
    }

    private var dataSourceFootnote: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle").font(.system(size: 10))
            Text("系统负载优先来自 IORegistry 系统遥测，离电时以电池放出功率估算，接电无遥测时不显示。CPU/GPU 为 powermetrics 模型估算；显示器按亮度估算。")
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - 当前负载英雄卡（每秒失效仅限此视图）

private struct PowerLoadHero: View {
    let sampler: PowerSampler

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.bbAmber.opacity(0.14))
                    .frame(width: 54, height: 54)
                Image(systemName: "cpu.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.bbAmber)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("系统负载")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(sourceText)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(sourceTint)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(sourceTint.opacity(0.1), in: Capsule())
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if sampler.currentPowerAvailable {
                        Text(String(format: "%.1f", sampler.currentWattage))
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text("W")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("不可用")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(batteryLine)
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .glassCard(accent: .bbAmber)
    }

    private var sourceText: String {
        if !sampler.currentPowerAvailable { return "当前不可用" }
        return sampler.currentPowerIsEstimated ? "电池侧估算" : "系统遥测"
    }

    private var sourceTint: Color {
        if !sampler.currentPowerAvailable { return .secondary }
        return sampler.currentPowerIsEstimated ? .orange : .bbMint
    }

    private var batteryLine: String {
        let direction = sampler.currentIsCharging ? "充入" : "放出"
        return String(format: "电池%@ %.1f W", direction, sampler.currentBatteryPower)
    }
}

// MARK: - 组件构成

/// 分项读数。占比只在「系统负载有效且组件样本新鲜（<30s）」时显示；
/// 否则只给绝对瓦数，不制造无意义的百分比。
private struct ComponentBreakdownCard: View {
    let sampler: PowerSampler

    /// powermetrics 与 App 均每 10s 产出/取缓存，超过 30s 视为陈旧。
    private static let freshnessLimit: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            SectionHeader(title: "负载构成", systemImage: "cpu.fill", tint: .bbPurple)

            if sampler.helperEnabled {
                componentBar(label: "CPU", value: sampler.cpuPower, icon: "cpu", color: .bbBlue, measured: true)
                componentBar(label: "GPU", value: sampler.gpuPower, icon: "square.stack.3d.up", color: .bbPurple, measured: true)
                if sampler.dramPower > 0 {
                    componentBar(label: "DRAM", value: sampler.dramPower, icon: "memorychip", color: .teal, measured: true)
                }
                if sampler.displayPower > 0 {
                    componentBar(label: "显示器（估算）", value: sampler.displayPower, icon: "display", color: .orange, measured: false)
                }
                stalenessNote
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").font(.system(size: 9))
                    Text("分项为模型估算，不能相加当作整机精密功率计").font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text("开启下方「分项功耗采样」后显示 CPU/GPU 模型估算")
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

    @ViewBuilder
    private var stalenessNote: some View {
        if Date().timeIntervalSince(sampler.lastComponentPowerAt) > Self.freshnessLimit {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9))
                Text("分项样本尚未就绪或已过期，正在等待下一轮").font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
    }

    private func componentBar(label: String, value: Double, icon: String, color: Color, measured: Bool) -> some View {
        let total = sampler.currentWattage
        let percentVisible = measured && sampler.currentPowerAvailable && !sampler.currentPowerIsEstimated
            && Date().timeIntervalSince(sampler.lastComponentPowerAt) <= Self.freshnessLimit
        let percentage = percentVisible && total > 0 ? min(100, value / total * 100) : 0
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(percentVisible ? String(format: "%.1f W · %.0f%%", value, percentage) : String(format: "%.1f W", value))
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(color.gradient)
                            .frame(width: geo.size.width * (percentVisible ? percentage / 100 : 0))
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

// MARK: - 电源诊断（默认折叠）

private struct PowerDiagnosticsSection: View {
    let sampler: PowerSampler
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 8) {
                    diagRow("电池电压", sampler.currentVoltage > 0 ? String(format: "%.0f mV", sampler.currentVoltage) : "—")
                    diagRow("瞬时电流", sampler.currentAmperage != 0 ? String(format: "%.0f mA", sampler.currentAmperage) : "—")
                    diagRow("电池温度", sampler.currentTemperature > 0.5 ? String(format: "%.1f °C", sampler.currentTemperature) : "—")
                    diagRow("适配器输入功率", adapterInputText)
                    diagRow("适配器额定功率", adapterWattsText)
                    diagRow("充电协议", sampler.currentInfo?.adapterProtocol ?? "—")
                }
                .padding(.top, 6)
            } label: {
                SectionHeader(title: "电源诊断", systemImage: "dial.min.fill", tint: .bbTeal)
            }
        }
        .glassCard(accent: .bbTeal)
    }

    private var adapterWattsText: String {
        guard let watts = sampler.currentInfo?.adapterWatts, watts > 0 else { return "—" }
        return String(format: "%.0f W", watts)
    }

    private var adapterInputText: String {
        let watts = sampler.currentAdapterInputPower
        guard watts > 0 else { return "—" }
        return String(format: "%.1f W", watts)
    }

    private func diagRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
        }
    }
}

// MARK: - 高级采样（Helper 开关，底部）

private struct AdvancedSamplingCard: View {
    let sampler: PowerSampler
    @Binding var isInstallingHelper: Bool

    var body: some View {
        let enabled = sampler.helperEnabled
        VStack(alignment: .leading, spacing: BBDesign.itemSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14))
                    .foregroundStyle(enabled ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("分项功耗采样（Helper）")
                        .font(.system(size: 13, weight: .semibold))
                    Text(enabled ? "已启用 — 独立每 10 秒持续采样，用于实时读数与分钟历史" : "默认关闭 — 不运行 powermetrics")
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
            if sampler.helperNeedsUpdate {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("Helper 需要更新；再次主动开启时会请求管理员授权").font(.system(size: 10))
                }
                .foregroundStyle(.orange)
            }
            HStack(spacing: 4) {
                Image(systemName: "info.circle").font(.system(size: 9))
                Text("开启需一次管理员授权，后台也会持续运行；结果适合观察本机趋势，不适合跨机型比较。关闭后零 powermetrics 调用").font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
        }
        .glassCard(accent: enabled ? .bbMint : .clear)
    }
}
