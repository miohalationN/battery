import SwiftUI

struct PopoverView: View {
    @ObservedObject var sampler: PowerSampler
    /// 打开主窗口（由 AppDelegate 注入：NSWindow 创建/激活逻辑收敛在 AppDelegate）
    var onOpenDetails: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusCard
            powerCard
            healthCard
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    // MARK: - 顶部：电量 + 状态

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 46, height: 46)
                Image(systemName: batterySymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(sampler.currentLevel))")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            Spacer()
        }
    }

    // MARK: - 状态卡片（充电 / 已插电 / 放电 统一结构）

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeadline
            batteryBar
            if !isChargingNow, !isPluggedIn {
                HStack(spacing: 0) {
                    durationItem("亮屏", minutes: sampler.screenOnTime, icon: "sun.max.fill", color: .yellow)
                    durationItem("休眠", minutes: sampler.sleepTime, icon: "moon.fill", color: .indigo)
                    powerItem
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var statusHeadline: some View {
        if isFullCharge {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("电池已充满").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("正在使用电源").font(.caption).foregroundStyle(.secondary)
            }
        } else if isChargingNow {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text(chargeHeadline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(wattageText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else if isPluggedIn {
            HStack(spacing: 6) {
                Image(systemName: "powerplug.fill").foregroundStyle(.secondary)
                Text("已插电，未充电").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(wattageText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "battery.25percent").foregroundStyle(drainColor)
                Text(drainHeadline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(wattageText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    /// 电量进度条：所有状态统一显示
    private var batteryBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15))
                RoundedRectangle(cornerRadius: 4)
                    .fill(barColor.gradient)
                    .frame(width: max(6, geo.size.width * sampler.currentLevel / 100))
            }
        }
        .frame(height: 6)
    }

    private var powerItem: some View {
        VStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(.orange)
            Text(wattageText).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Text("当前功率").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func durationItem(_ title: String, minutes: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            Text("\(minutes / 60)h \(minutes % 60)m")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 实时功耗卡片

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("实时功耗")
            powerRow("总功率", value: String(format: "%.1f W", sampler.currentWattage), icon: "bolt.fill", color: .orange)
            if sampler.helperEnabled {
                powerRow("CPU", value: String(format: "%.1f W", sampler.cpuPower), icon: "cpu", color: .blue)
                powerRow("GPU", value: String(format: "%.1f W", sampler.gpuPower), icon: "gpu", color: .green)
                if sampler.dramPower > 0 {
                    powerRow("内存", value: String(format: "%.1f W", sampler.dramPower), icon: "memorychip", color: .teal)
                }
            }
            if sampler.displayPower > 0 {
                powerRow("显示器", value: String(format: "%.1f W", sampler.displayPower), icon: "display", color: .yellow)
            }
            // 原始电学量降级为次要信息
            if sampler.currentVoltage > 0 {
                HStack(spacing: 4) {
                    Spacer()
                    Text(String(format: "%.1f V · %@ mA", sampler.currentVoltage / 1000, formatAmperage))
                        .font(.system(size: 10, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .cardStyle()
    }

    private var formatAmperage: String {
        String(format: "%.0f", sampler.currentAmperage)
    }

    // MARK: - 电池健康卡片

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("电池健康")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.0f", sampler.systemHealthPercent))
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(healthColor)
                Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(healthLabel)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(healthColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(healthColor)
            }
            healthRow("循环次数", value: "\(sampler.currentInfo?.cycleCount ?? 0) 次", icon: "arrow.triangle.2.circlepath")
            healthRow("满充容量", value: capacityText, icon: "battery.100")
            healthRow("温度", value: temperatureText, icon: "thermometer")
        }
        .cardStyle()
    }

    private var capacityText: String {
        guard let info = sampler.currentInfo, info.maxCapacity > 0, info.designCapacity > 0 else { return "—" }
        return "\(info.maxCapacity) / \(info.designCapacity) mAh"
    }

    private var temperatureText: String {
        sampler.currentTemperature > 0.5 ? String(format: "%.1f°C", sampler.currentTemperature) : "—"
    }

    private var healthLabel: String {
        if sampler.systemHealthPercent >= 90 { return "良好" }
        if sampler.systemHealthPercent >= 80 { return "一般" }
        return "建议检修"
    }

    private var healthColor: Color {
        if sampler.systemHealthPercent >= 90 { return .green }
        if sampler.systemHealthPercent >= 80 { return .orange }
        return .red
    }

    // MARK: - 底部操作区

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                onOpenDetails()
                dismiss()
            } label: {
                Label("查看详情", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            HStack {
                Button {
                    sampler.openBatterySettings()
                } label: {
                    Label("电池设置", systemImage: "gear")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 通用小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func powerRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    private func healthRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    // MARK: - 计算属性

    private var isPluggedIn: Bool { sampler.currentInfo?.externalConnected ?? false }
    private var isChargingNow: Bool { sampler.currentIsCharging }
    private var isFullCharge: Bool { isPluggedIn && sampler.currentLevel >= 100 }

    private var wattageText: String {
        sampler.currentWattage > 0.05 ? String(format: "%.1fW", sampler.currentWattage) : "—"
    }

    private var chargeHeadline: String {
        let rate = sampler.cachedChargeRate
        guard rate > 0 else { return "充电中" }
        let timeToFull = (100 - sampler.currentLevel) / rate
        let h = Int(timeToFull); let m = Int((timeToFull - Double(h)) * 60)
        return "预计 \(h)h \(m)m 后充满"
    }

    private var drainHeadline: String {
        let rate = sampler.cachedDrainRate
        guard rate > 0 else { return "放电中" }
        // 考虑 5% 放电截止保护
        let usableLevel = max(0, sampler.currentLevel - 5)
        let remaining = usableLevel / rate
        let h = Int(remaining); let m = Int((remaining - Double(h)) * 60)
        return "剩余约 \(h)h \(m)m"
    }

    private var drainColor: Color {
        sampler.currentLevel <= 20 ? .red : .accentColor
    }

    private var barColor: Color {
        if isChargingNow { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .accentColor
    }

    private var statusColor: Color {
        if sampler.currentLevel >= 100 { return .green }
        if sampler.currentIsCharging { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .accentColor
    }

    private var statusText: String {
        if sampler.currentLevel >= 100 && isPluggedIn { return "已充满" }
        if sampler.currentIsCharging { return "充电中" }
        if isPluggedIn { return "已插电" }
        return "放电中"
    }

    private var batterySymbol: String {
        if sampler.currentIsCharging { return "battery.100percent.bolt" }
        switch sampler.currentLevel {
        case 100...: return "battery.100percent"
        case 0...10: return "battery.0percent"
        case 11...25: return "battery.25percent"
        case 26...50: return "battery.50percent"
        case 51...75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: - 卡片样式

private extension View {
    /// 统一卡片样式：圆角 + 半透明填充，替代旧版的 Divider 分隔
    func cardStyle() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
