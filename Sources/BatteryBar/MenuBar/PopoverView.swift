import SwiftUI

struct PopoverView: View {
    let sampler: PowerSampler
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            brandBar
            header
            statusCard
            powerCard
            healthCard
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    LinearGradient(
                        colors: [Color.bbBlue.opacity(0.065), Color.clear, Color.bbMint.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
        }
    }

    private var brandBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(AppBrand.displayName)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                Text("电池与能耗监控")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            LiveBadge(text: "实时", tint: .bbMint)
        }
        .padding(.horizontal, 2)
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
            if sampler.powerSourceState == .onBattery {
                HStack(spacing: 0) {
                    durationItem("亮屏", minutes: sampler.screenOnTime, icon: "sun.max.fill", color: .bbAmber)
                    durationItem("休眠", minutes: sampler.sleepTime, icon: "moon.fill", color: .indigo)
                    powerItem
                }
            }
        }
        .cardStyle(accent: barColor)
    }

    @ViewBuilder
    private var statusHeadline: some View {
        switch sampler.powerSourceState {
        case .onPowerNotCharging where sampler.currentLevel >= 100:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("电池已充满").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("正在使用电源").font(.caption).foregroundStyle(.secondary)
            }
        case .charging:
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text(chargeHeadline)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(wattageText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .onPowerNotCharging:
            // 满电保持 / 优化充电暂停 / 80% 上限：接电但电池未充入，不是离电
            HStack(spacing: 6) {
                Image(systemName: "powerplug.fill").foregroundStyle(.secondary)
                Text("已接电，未充电").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(wattageText)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .onBattery:
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
            Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(Color.bbAmber)
            Text(wattageText).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            Text("电池功率").font(.system(size: 10)).foregroundStyle(.secondary)
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
            HStack {
                sectionTitle("实时功耗")
                Spacer()
                Text(loadSourceText)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(loadSourceTint)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(loadSourceTint.opacity(0.1), in: Capsule())
            }
            powerRow("系统负载", value: loadValueText, icon: "cpu.fill", color: .bbAmber)
            powerRow(sampler.currentIsCharging ? "电池充入" : "电池放出",
                     value: String(format: "%.1f W", sampler.currentBatteryPower),
                     icon: "bolt.fill", color: .bbBlue)
            if sampler.helperEnabled {
                powerRow("CPU", value: String(format: "%.1f W", sampler.cpuPower), icon: "cpu", color: .bbBlue)
                powerRow("GPU", value: String(format: "%.1f W", sampler.gpuPower), icon: "gpu", color: .bbPurple)
                if sampler.dramPower > 0 {
                    powerRow("内存", value: String(format: "%.1f W", sampler.dramPower), icon: "memorychip", color: .teal)
                }
            }
            if sampler.displayPower > 0 {
                powerRow("显示器（估算）", value: String(format: "%.1f W", sampler.displayPower), icon: "display", color: .yellow)
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
        .cardStyle(accent: .bbAmber)
    }

    /// 系统负载标注数据来源；接电无遥测时明确不可用，不用充电功率冒充
    private var loadValueText: String {
        sampler.currentPowerAvailable ? String(format: "%.1f W", sampler.currentWattage) : "—"
    }

    private var loadSourceText: String {
        if !sampler.currentPowerAvailable { return "负载不可用" }
        return sampler.currentPowerIsEstimated ? "负载·电池侧估算" : "负载·系统遥测"
    }

    private var loadSourceTint: Color {
        if !sampler.currentPowerAvailable { return .secondary }
        return sampler.currentPowerIsEstimated ? .orange : .bbMint
    }

    private var formatAmperage: String {
        String(format: "%.0f", sampler.currentAmperage)
    }

    // MARK: - 电池健康卡片

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("电池健康")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sampler.systemHealthPercent > 0 ? String(format: "%.0f", sampler.systemHealthPercent) : "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(healthColor)
                if sampler.systemHealthPercent > 0 {
                    Text("%").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
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
        .cardStyle(accent: .bbMint)
    }

    private var capacityText: String {
        guard let info = sampler.currentInfo, info.maxCapacity > 0, info.designCapacity > 0 else { return "—" }
        return "\(info.maxCapacity) / \(info.designCapacity) mAh"
    }

    private var temperatureText: String {
        sampler.currentTemperature > 0.5 ? String(format: "%.1f°C", sampler.currentTemperature) : "—"
    }

    private var healthLabel: String {
        if sampler.systemHealthPercent <= 0 { return "暂不可用" }
        if sampler.systemHealthPercent >= 90 { return "良好" }
        if sampler.systemHealthPercent >= 80 { return "一般" }
        return "建议检修"
    }

    private var healthColor: Color {
        if sampler.systemHealthPercent <= 0 { return .secondary }
        if sampler.systemHealthPercent >= 90 { return .green }
        if sampler.systemHealthPercent >= 80 { return .orange }
        return .red
    }

    // MARK: - 底部操作区

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                openMainWindow()
                dismiss()
            } label: {
                Label("查看详情", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .adaptiveProminentButton(tint: .bbBlue)

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

    /// 与主窗口同一状态定义：三态 + 满电由 level 组合表达
    private var isPluggedIn: Bool { sampler.currentExternalConnected }
    private var isChargingNow: Bool { sampler.currentIsCharging }
    private var isFullCharge: Bool { isPluggedIn && sampler.currentLevel >= 100 }

    private var wattageText: String {
        // 状态行跟随电池侧功率（充电=充入、放电=放出），系统负载单独标注来源
        sampler.currentBatteryPower > 0.05 ? String(format: "%.1fW", sampler.currentBatteryPower) : "—"
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
        sampler.currentLevel <= 20 ? .red : .bbBlue
    }

    private var barColor: Color {
        if isChargingNow { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .bbBlue
    }

    private var statusColor: Color {
        switch sampler.powerSourceState {
        case .charging: return .green
        case .onPowerNotCharging: return .bbTeal
        case .onBattery: return sampler.currentLevel <= 20 ? .red : .bbBlue
        }
    }

    private var statusText: String {
        switch sampler.powerSourceState {
        case .onPowerNotCharging:
            return isFullCharge ? "已充满" : "已接电，未充电"
        case .charging: return "充电中"
        case .onBattery: return "离电使用中"
        }
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

    // MARK: - 主窗口控制

    private func openMainWindow() {
        // 单例窗口控制：若已有主窗口则激活它，否则新建
        if let existing = findExistingMainWindow() {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if existing.isMiniaturized { existing.deminiaturize(nil) }
        } else {
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = findExistingMainWindow() {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    /// 查找已存在的主窗口（SwiftUI WindowGroup 创建的 ContentView 所在窗口）。
    /// 判断依据：
    ///   1. 排除 MenuBarExtra 的 popover（className 含 "MenuExtra" 或 "_NSMenuExtra"）
    ///   2. 排除已最小化或不可见的窗口
    ///   3. 主窗口默认 760x580，popover 宽度只有 340，用 frame.width > 500 区分
    ///   4. contentView 不为 nil 且能成为 key window
    private func findExistingMainWindow() -> NSWindow? {
        return NSApp.windows.first { window in
            // 排除 MenuBarExtra popover（私有类名特征）
            let className = String(describing: type(of: window))
            if className.contains("MenuExtra") || className.contains("_NSMenuExtra") {
                return false
            }
            // 必须可见、有 contentView、能成为 key
            guard window.contentView != nil,
                  window.canBecomeKey,
                  !window.isMiniaturized,
                  window.isVisible else {
                return false
            }
            // 主窗口默认 760 宽，popover 340 宽，用 500 作为分界
            return window.frame.width > 500
        }
    }
}

// MARK: - 卡片样式

private extension View {
    /// Popover 专用紧凑卡片：用淡彩边缘区分信息类型，不增加厚重阴影。
    func cardStyle(accent: Color = .clear) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.038))
                    .overlay {
                        LinearGradient(
                            colors: [accent.opacity(0.085), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.065), lineWidth: 1)
            }
    }
}
