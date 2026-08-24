import SwiftUI
import AppKit
import ServiceManagement
import ImageIO

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口 — WindowGroup 配合单例控制，避免反复 openWindow 创建多窗口
        // sampler / syncEngine 由 AppDelegate 持有，状态栏/主窗口/popover 共用同一实例。
        // SwiftUI 窗口生命周期提供液态玻璃材质所需的窗口 chrome（2026-08-22 曾试改
        // 裸 NSWindow + NSHostingController，材质渲染退化，已回滚）。
        WindowGroup(id: "main") {
            ContentView()
                .environment(appDelegate.sampler)
                .environment(appDelegate.loginItem)
                .environmentObject(appDelegate.syncEngine)
                .background(OpenWindowRelay())
                .onAppear {
                    appDelegate.sampler.start()
                    appDelegate.sampler.setReadingSurface(.mainWindow, visible: true)
                    // 打开主窗口时显示 Dock 图标
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    appDelegate.sampler.setReadingSurface(.mainWindow, visible: false)
                    // 关闭主窗口时隐藏 Dock 图标，回到纯菜单栏模式
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 660)
    }

    init() {
        // App bundle 优先使用正式图标；直接运行 SPM 裸二进制时保留代码绘制兜底。
        #if SWIFT_PACKAGE
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        #else
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
        #endif
        if let url = iconURL,
           let image = Self.runtimeIcon(from: url) {
            NSApplication.shared.applicationIconImage = image
        } else {
            NSApplication.shared.applicationIconImage = Self.drawAppIcon()
        }
    }

    /// Finder/Dock 继续由完整 ICNS 提供所有尺寸；进程内只显示 28–56pt 图标，没必要
    /// 常驻解码 1024px PNG。缩成 256px 可显著降低 CG Image 物理页占用。
    private static func runtimeIcon(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 256, height: 256))
    }

    /// 用 CoreGraphics 绘制 1024×1024 电池图标作为 App 图标
    private static func drawAppIcon() -> NSImage {
        let size = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = CGRect(origin: .zero, size: size)
        // 背景：深色圆角矩形（macOS 图标风格）
        NSColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 224, yRadius: 224).fill()

        // 电池主体：圆角矩形，居中
        let batteryW: CGFloat = 560
        let batteryH: CGFloat = 320
        let batteryX = (rect.width - batteryW) / 2
        let batteryY = (rect.height - batteryH) / 2
        let batteryRect = CGRect(x: batteryX, y: batteryY, width: batteryW, height: batteryH)

        // 外壳：白色描边
        NSColor.white.setStroke()
        let shell = NSBezierPath(roundedRect: batteryRect, xRadius: 48, yRadius: 48)
        shell.lineWidth = 28
        shell.stroke()

        // 正极凸起：右侧小矩形
        let capW: CGFloat = 36
        let capH: CGFloat = 140
        let capRect = CGRect(
            x: batteryRect.maxX + 8,
            y: batteryRect.midY - capH / 2,
            width: capW,
            height: capH
        )
        let cap = NSBezierPath(roundedRect: capRect, xRadius: 12, yRadius: 12)
        NSColor.white.setFill()
        cap.fill()

        // 内部填充：绿色（约 75% 电量）
        let inset: CGFloat = 36
        let fillW = (batteryRect.width - inset * 2) * 0.75
        let fillRect = CGRect(
            x: batteryRect.minX + inset,
            y: batteryRect.minY + inset,
            width: fillW,
            height: batteryRect.height - inset * 2
        )
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 24, yRadius: 24)
        NSColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 1.0).setFill()
        fill.fill()

        // 闪电符号：居中白色
        let boltCenter = CGPoint(x: batteryRect.midX, y: batteryRect.midY)
        let bolt = NSBezierPath()
        bolt.move(to: CGPoint(x: boltCenter.x - 30, y: boltCenter.y + 70))
        bolt.line(to: CGPoint(x: boltCenter.x + 50, y: boltCenter.y - 10))
        bolt.line(to: CGPoint(x: boltCenter.x + 5, y: boltCenter.y - 10))
        bolt.line(to: CGPoint(x: boltCenter.x + 30, y: boltCenter.y - 70))
        bolt.line(to: CGPoint(x: boltCenter.x - 50, y: boltCenter.y + 10))
        bolt.line(to: CGPoint(x: boltCenter.x - 5, y: boltCenter.y + 10))
        bolt.close()
        NSColor.white.setFill()
        bolt.fill()

        image.unlockFocus()
        return image
    }
}

/// AppDelegate — 状态栏（左键 Popover / 右键菜单）、开机自启；主窗口归 WindowGroup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var aboutWindow: NSWindow?
    private var observer: NSObjectProtocol?
    private var loginItemActivationObserver: NSObjectProtocol?
    // refreshTitle 门控：文字与低电量态都没变时跳过（title/length 赋值会触发菜单栏重排）
    private var lastTitleText: String?
    private var lastTitleLowBattery = false

    let sampler = PowerSampler()
    let syncEngine = SyncEngine()
    /// 开机自启动共享状态：右键菜单与设置页 Toggle 共用，禁止两套逻辑漂移
    let loginItem = LoginItemState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sampler.start()
        loginItem.refresh()

        // 通知设置初始化：只查询授权状态、绝不请求权限（策略见 NotificationManager）
        NotificationManager.shared.attachSystemPresentationDelegate()
        Task { @MainActor in
            await NotificationManager.shared.start()
        }

        // 应用重新激活后刷新系统设置中的真实状态。通知路径只查询授权，绝不请求权限。
        loginItemActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loginItem.refresh()
                Task { @MainActor in
                    await NotificationManager.shared.refreshAuthorization()
                }
            }
        }

        // 启动时让自动同步调度器与持久化配置一致
        let config = DataStore.shared.currentConfig()
        syncEngine.applySchedule(config: config)

        // 初始用 variableLength，后续在 refreshTitle 中改为固定值
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.title = "—"
            button.image = nil
            button.font = NSFont.menuBarFont(ofSize: 0)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 左键弹 Popover，右键弹菜单（在 statusItemClicked 中按事件类型分流）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 监听 sampler 变化，更新文字（queue: .main 保证闭包在主线程，assumeIsolated 同步直达）
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PowerSamplerDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTitle()
            }
        }

        // 创建 popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 536)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverMenuBarView(sampler: sampler)
        )
        self.popover = popover

        // 延迟触发一次刷新（等 sampler 第一次采样完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshTitle()
        }
    }

    // MARK: - 状态栏点击分流（左键 Popover / 右键菜单）

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            guard let item = statusItem else { return }
            // 临时挂载菜单让系统显示它，显示完移除，恢复左键 Popover 行为
            item.menu = buildStatusMenu()
            item.button?.performClick(nil)
            item.menu = nil
        default:
            togglePopover(sender)
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        // 主窗口归 WindowGroup 管理：发通知由 ContentView 内的 openWindow 打开
        let openItem = menu.addItem(withTitle: "打开主窗口", action: #selector(openMainWindowFromMenu(_:)), keyEquivalent: "")
        openItem.target = self

        let loginItem = menu.addItem(withTitle: "开机自启动", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        // 与设置页 Toggle 共用同一 LoginItemState；requiresApproval 不得假装已开启
        if self.loginItem.isOn {
            loginItem.state = .on
        } else {
            loginItem.state = .off
            if self.loginItem.needsApproval {
                loginItem.title = "开机自启动（需要在系统设置中允许）"
            }
        }

        menu.addItem(.separator())

        let settingsItem = menu.addItem(withTitle: "电池设置…", action: #selector(openBatterySettingsFromMenu(_:)), keyEquivalent: "")
        settingsItem.target = self

        let aboutItem = menu.addItem(withTitle: "关于 \(AppBrand.shortName)", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        // target 为 nil 走响应链，最终由 NSApplication 处理 terminate
        menu.addItem(withTitle: "退出 \(AppBrand.shortName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openMainWindowFromMenu(_ sender: Any?) {
        NotificationCenter.default.post(name: .init("OpenMainWindowRequested"), object: nil)
    }

    @objc private func openBatterySettingsFromMenu(_ sender: Any?) {
        sampler.openBatterySettings()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "关于 \(AppBrand.shortName)"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AboutPanelView())
            aboutWindow = window
        }
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 开机自启动（与设置页共用 LoginItemState）

    @objc private func toggleLoginItem(_ sender: Any?) {
        loginItem.refresh()
        if let message = loginItem.setEnabled(!loginItem.isOn) {
            let alert = NSAlert()
            alert.messageText = "开机自启动设置失败"
            alert.informativeText = "\(message)\n若系统要求批准，请在「系统设置 → 通用 → 登录项」中允许\(AppBrand.localizedName)。"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: Any?) {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        sampler.setReadingSurface(.statusPopover, visible: true)
    }

    func popoverDidClose(_ notification: Notification) {
        sampler.setReadingSurface(.statusPopover, visible: false)
    }

    /// 更新状态栏文字（跟随系统逻辑：纯百分比，不显示预估时间）
    /// 低电量（≤20% 且未充电）时文字变红。
    ///
    /// 宽度控制：button.attributedTitle + 固定 statusItem.length（NSAttributedString 精确测宽 + ceil + 2pt）。
    /// 不再用 NSTextField 子视图方案——macOS 27 上 NSTextField 嵌入 NSStatusBarButton
    /// 会触发 AppKit 布局引擎持续重排，实测空转约 37% CPU（2026-08-22，见 T-30）。
    private func refreshTitle() {
        let level = Int(sampler.currentLevel)
        let text = "\(level)%"
        let lowBattery = level <= 20 && !sampler.currentIsCharging

        // 每秒采样通知到达，但内容未变时跳过：title/length 赋值会触发菜单栏重排
        guard text != lastTitleText || lowBattery != lastTitleLowBattery else { return }
        lastTitleText = text
        lastTitleLowBattery = lowBattery

        guard let button = statusItem?.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        // 低电量变红；labelColor 为动态色，自动跟随系统深浅模式
        let color: NSColor = lowBattery ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        // 精确宽度：attributed size（含字体全要素）→ ceil 防小数裁切 + 2pt 余量防 % 边缘被裁
        let width = ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2
        statusItem?.length = width
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampler.stop()
        syncEngine.stop()
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = loginItemActivationObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }
}

enum AppSection: Int, CaseIterable, Identifiable {
    case overview
    case cycles
    case power
    case sync

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overview: return "电池概览"
        case .cycles: return "离电记录"
        case .power: return "功耗分析"
        case .sync: return "数据与同步"
        }
    }

    var shortTitle: String {
        switch self {
        case .overview: return "概览"
        case .cycles: return "记录"
        case .power: return "功耗"
        case .sync: return "同步"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "battery.75percent"
        case .cycles: return "list.bullet.rectangle"
        case .power: return "waveform.path.ecg"
        case .sync: return "arrow.triangle.branch"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .bbMint
        case .cycles: return .bbBlue
        case .power: return .bbAmber
        case .sync: return .bbPurple
        }
    }
}

/// 主窗口采用固定侧栏 + 内容画布，稳定承载高密度图表并保留 macOS 原生窗口行为。
struct ContentView: View {
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var selectedSection: AppSection = ProfileSupport.initialSection ?? .overview
    @Namespace private var sidebarGlassNamespace

    var body: some View {
        ZStack {
            AppBackdrop()
            HStack(spacing: 0) {
                appSidebar
                Group {
                    switch selectedSection {
                    case .overview:
                        UsageTab()
                    case .cycles:
                        CycleTab()
                    case .power:
                        PowerTab()
                    case .sync:
                        SyncTab(syncEngine: syncEngine)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, minHeight: 580)
    }

    private var appSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppBrand.displayName)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(AppBrand.tagline)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            sidebarNavigation
            .padding(.horizontal, 10)

            Spacer(minLength: 16)
            SidebarBatteryStatus()
                .padding(12)
        }
        .padding(.top, 48)
        .frame(width: BBDesign.sidebarWidth)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
        }
    }

    @ViewBuilder
    private var sidebarNavigation: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 5) {
                sidebarButtons
            }
        } else {
            sidebarButtons
        }
    }

    private var sidebarButtons: some View {
        VStack(spacing: 5) {
            ForEach(AppSection.allCases) { section in
                sidebarButton(section)
            }
        }
    }

    @ViewBuilder
    private func sidebarButton(_ section: AppSection) -> some View {
        let isSelected = selectedSection == section
        if #available(macOS 26.0, *), isSelected {
            sidebarButtonBase(section, isSelected: true)
                .glassEffect(
                    .regular.tint(section.tint.opacity(0.18)).interactive(),
                    in: .rect(cornerRadius: 10)
                )
                .glassEffectID("sidebar-selection", in: sidebarGlassNamespace)
        } else {
            sidebarButtonBase(section, isSelected: isSelected)
        }
    }

    private func sidebarButtonBase(_ section: AppSection, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? section.tint : Color.secondary)
                    .frame(width: 18)
                Text(section.shortTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Spacer()
                if isSelected {
                    Circle()
                        .fill(section.tint)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background {
                if #available(macOS 26.0, *) {
                    Color.clear
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? section.tint.opacity(0.105) : Color.clear)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? section.tint.opacity(0.14) : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

/// 把每秒变化的实时状态隔离在小视图内，避免 ContentView 的导航与页面路由一起失效。
private struct SidebarBatteryStatus: View {
    @Environment(PowerSampler.self) private var sampler

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("当前电量")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Circle()
                    .fill(sidebarStatusColor)
                    .frame(width: 6, height: 6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(sampler.currentLevel))")
                    .font(.system(size: 25, weight: .bold, design: .rounded).monospacedDigit())
                Text("%")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: sampler.currentIsCharging ? "bolt.fill" : "battery.75percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(sidebarStatusColor)
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(sidebarStatusColor.gradient)
                            .frame(width: max(4, geometry.size.width * sampler.currentLevel / 100))
                    }
            }
            .frame(height: 5)
            Text(sampler.currentIsCharging ? "正在充电" : sidebarPowerText)
                .font(.system(size: 9, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    /// 离电时系统负载与电池放出功率等价（估算）；接电无遥测时负载不可用，
    /// 显示电池功率并如实标注，不冒充系统总功耗。
    private var sidebarPowerText: String {
        if sampler.currentPowerAvailable {
            return String(format: "系统负载 %.1f W", sampler.currentWattage)
        }
        return String(format: "电池功率 %.1f W", sampler.currentBatteryPower)
    }

    private var sidebarStatusColor: Color {
        if sampler.currentIsCharging { return .bbMint }
        if sampler.currentLevel <= 20 { return .red }
        return .bbBlue
    }
}

/// 状态栏弹窗
struct PopoverMenuBarView: View {
    let sampler: PowerSampler

    var body: some View {
        PopoverView(sampler: sampler)
            .frame(width: 340)
    }
}

/// 右键菜单「打开主窗口」的中继：主窗口归 WindowGroup 管理，
/// openWindow 环境只在视图内可用，通过通知把请求转进来
private struct OpenWindowRelay: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .init("OpenMainWindowRequested"))) { _ in
                openWindow(id: "main")
            }
    }
}
