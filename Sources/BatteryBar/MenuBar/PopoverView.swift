import SwiftUI

struct PopoverView: View {
    @ObservedObject var sampler: PowerSampler
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            statusInfo
            Divider().padding(.horizontal, 16)
            powerSection
            Divider().padding(.horizontal, 16)
            healthSection
            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: 320)
        .background { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: batterySymbol)
                    .font(.system(size: 24, weight: .medium))
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
        .padding(16)
    }

    @ViewBuilder
    private var statusInfo: some View {
        // 满电状态：必须连接电源且电量 >= 100。拔电后即使 100% 也按离电处理。
        let isPluggedIn = sampler.currentInfo?.externalConnected ?? false
        let isFullCharge = isPluggedIn && sampler.currentLevel >= 100

        if isFullCharge {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("电池已充满").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("正在使用电源").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        } else if sampler.currentIsCharging {
            let rate = sampler.cachedChargeRate
            let timeToFull = rate > 0 ? (100 - sampler.currentLevel) / rate : 0
            let h = Int(timeToFull); let m = Int((timeToFull - Double(h)) * 60)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                    Text("预计 \(h)h \(m)m 后充满")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(String(format: "%.1fW", sampler.currentWattage))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.gradient)
                            .frame(width: geo.size.width * sampler.currentLevel / 100)
                    }
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        } else {
            let rate = sampler.cachedDrainRate
            // 考虑5%放电截止保护
            let usableLevel = max(0, sampler.currentLevel - 5)
            let remaining = rate > 0 ? usableLevel / rate : 0
            let h = Int(remaining); let m = Int((remaining - Double(h)) * 60)

            HStack(spacing: 0) {
                durationItem("亮屏", minutes: sampler.screenOnTime, icon: "sun.max.fill", color: .yellow)
                durationItem("休眠", minutes: sampler.sleepTime, icon: "moon.fill", color: .indigo)
                VStack(spacing: 5) {
                    Image(systemName: "clock.fill").font(.system(size: 15)).foregroundStyle(.blue)
                    if rate > 0 {
                        Text("\(h)h \(m)m").font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    } else {
                        Text("计算中").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            .padding(.vertical, 14)
        }
    }

    private func durationItem(_ title: String, minutes: Int, icon: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(color)
            Text("\(minutes / 60)h \(minutes % 60)m")
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时功耗").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 16)
            VStack(spacing: 8) {
                powerRow("总功率", value: String(format: "%.1f W", sampler.currentWattage), icon: "bolt.fill", color: .yellow)
                if sampler.helperEnabled {
                    powerRow("CPU", value: String(format: "%.1f W", sampler.cpuPower), icon: "cpu", color: .blue)
                    powerRow("GPU", value: String(format: "%.1f W", sampler.gpuPower), icon: "gpu", color: .green)
                    if sampler.dramPower > 0 {
                        powerRow("内存", value: String(format: "%.1f W", sampler.dramPower), icon: "memorychip", color: .teal)
                    }
                }
                if sampler.displayPower > 0 {
                    powerRow("显示器", value: String(format: "%.1f W", sampler.displayPower), icon: "display", color: .orange)
                }
                powerRow("电压", value: String(format: "%.0f mV", sampler.currentVoltage), icon: "bolt", color: .blue)
                powerRow("电流", value: String(format: "%.0f mA", sampler.currentAmperage), icon: "arrow.left.arrow.right", color: .green)
            }.padding(.horizontal, 16)
        }
        .padding(.vertical, 14)
    }

    private func powerRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("电池健康").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 16)
            if let info = sampler.currentInfo {
                VStack(spacing: 8) {
                    healthRow("循环次数", value: "\(info.cycleCount) 次", icon: "arrow.triangle.2.circlepath")
                    healthRow("容量", value: "\(info.maxCapacity)/\(info.designCapacity) mAh", icon: "battery.100")
                    healthRow("温度", value: String(format: "%.1f°C", sampler.currentTemperature), icon: "thermometer")
                    healthRow("健康度", value: String(format: "%.0f%%", sampler.systemHealthPercent), icon: "heart.fill")
                }.padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
    }

    private func healthRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button {
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
                    // 关闭 popover
                    dismiss()
                } label: {
                    Label("查看详情", systemImage: "chevron.right.circle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            HStack(spacing: 16) {
                Button {
                    sampler.openBatterySettings()
                } label: {
                    Label("电池设置", systemImage: "gear")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
        }
        .padding(14)
    }

    // MARK: - 计算

    private var statusColor: Color {
        if sampler.currentLevel >= 100 { return .green }
        if sampler.currentIsCharging { return .green }
        if sampler.currentLevel <= 20 { return .red }
        return .accentColor
    }

    private var statusText: String {
        if sampler.currentLevel >= 100 { return "已充满" }
        if sampler.currentIsCharging { return "充电中" }
        return String(format: "%.1fW 放电中", sampler.currentWattage)
    }

    private var batterySymbol: String {
        if sampler.currentLevel >= 100 { return "battery.100" }
        if sampler.currentIsCharging { return "battery.100.bolt" }
        switch sampler.currentLevel {
        case 0...10: return "battery.0percent"
        case 11...25: return "battery.25percent"
        case 26...50: return "battery.50percent"
        case 51...75: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// 查找已存在的主窗口（SwiftUI WindowGroup 创建的 ContentView 所在窗口）。
    /// 判断依据：
    ///   1. 排除 MenuBarExtra 的 popover（className 含 "MenuExtra" 或 "_NSMenuExtra"）
    ///   2. 排除已最小化或不可见的窗口
    ///   3. 主窗口默认 760x580，popover 宽度只有 320，用 frame.width > 500 区分
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
            // 主窗口默认 760 宽，popover 320 宽，用 500 作为分界
            return window.frame.width > 500
        }
    }
}
