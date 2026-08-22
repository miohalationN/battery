import SwiftUI
import AppKit
import ServiceManagement

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
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.syncEngine)
                .background(OpenWindowRelay())
                .onAppear {
                    appDelegate.sampler.start()
                    // 打开主窗口时显示 Dock 图标
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    // 关闭主窗口时隐藏 Dock 图标，回到纯菜单栏模式
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 580)
    }

    init() {
        // 设置 App 图标（运行时绘制，无需外部资源）
        NSApplication.shared.applicationIconImage = Self.drawAppIcon()
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
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var observer: NSObjectProtocol?
    // refreshTitle 门控：文字与低电量态都没变时跳过（title/length 赋值会触发菜单栏重排）
    private var lastTitleText: String?
    private var lastTitleLowBattery = false

    let sampler = PowerSampler()
    let syncEngine = SyncEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sampler.start()

        // 启动自动同步：仅在配置启用且间隔非手动时启动
        let config = DataStore.shared.currentConfig()
        if config.isEnabled && config.syncInterval != .manual {
            syncEngine.start(config: config)
        }

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
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.behavior = .transient
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
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())

        let settingsItem = menu.addItem(withTitle: "电池设置…", action: #selector(openBatterySettingsFromMenu(_:)), keyEquivalent: "")
        settingsItem.target = self

        let aboutItem = menu.addItem(withTitle: "关于 BatteryBar", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        // target 为 nil 走响应链，最终由 NSApplication 处理 terminate
        menu.addItem(withTitle: "退出 BatteryBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - 开机自启动（SMAppService Login Item）

    @objc private func toggleLoginItem(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // 常见失败原因：直接运行 .build 里的裸二进制（无 bundle），或 bundle 不在可注册位置
            let alert = NSAlert()
            alert.messageText = "开机自启动设置失败"
            alert.informativeText = "\(error.localizedDescription)\n请确认 BatteryBar 已安装到「应用程序」或个人目录的「应用程序」。"
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
    }
}

/// 主窗口内容
/// 沉浸式顶栏：.hiddenTitleBar 隐藏系统标题栏，系统 TabView 的居中液态玻璃
/// Tab 模块上移至红绿灯同一层；内容与顶栏之间无分割线
struct ContentView: View {
    @EnvironmentObject var sampler: PowerSampler
    @EnvironmentObject var syncEngine: SyncEngine
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            UsageTab(sampler: sampler)
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            CycleTab()
                .tabItem { Label("循环统计", systemImage: "arrow.triangle.2.circlepath") }
                .tag(1)

            PowerTab(sampler: sampler)
                .tabItem { Label("组件功耗", systemImage: "bolt.fill") }
                .tag(2)

            SyncTab(syncEngine: syncEngine)
                .tabItem { Label("同步", systemImage: "arrow.triangle.branch") }
                .tag(3)
        }
        .padding(.top, 2)
        .background(.thickMaterial)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// 状态栏弹窗
struct PopoverMenuBarView: View {
    @ObservedObject var sampler: PowerSampler

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
