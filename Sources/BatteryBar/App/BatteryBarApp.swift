import SwiftUI
import AppKit
import ServiceManagement

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口由 AppDelegate 以 NSWindow + NSHostingController 管理（见 showMainWindow），
        // 不用 SwiftUI WindowGroup：启动时保持纯菜单栏不开窗，右键菜单和 Popover
        // 都能直接拉起主窗口，也避免 WindowGroup 自动开窗与激活策略切换的时序问题。
        Settings { EmptyView() }
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

/// AppDelegate — 状态栏（左键 Popover / 右键菜单）、主窗口（NSWindow）、开机自启。
/// 整体隔离在 MainActor：持有 @MainActor 的 PowerSampler/SyncEngine，
/// 且所有入口（生命周期回调、target-action、窗口代理）都在主线程。
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var mainWindow: NSWindow?
    let sampler = PowerSampler()
    let syncEngine = SyncEngine()
    // 各 Tab 视图状态模型（@Observable）：AppDelegate 持有，跨窗口关闭/重开保留
    let usageModel = UsageTabModel()
    let cycleModel = CycleTabModel()
    let powerModel = PowerTabModel()
    let syncModel = SyncTabModel()
    private var observer: NSObjectProtocol?
    private var textField: NSTextField?

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
            button.title = ""
            button.image = nil
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 左键弹 Popover，右键弹菜单（在 statusItemClicked 中按事件类型分流）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // 用 NSTextField 替代 button.title，精确控制宽度
            let tf = NSTextField(labelWithString: "—")
            tf.font = NSFont.menuBarFont(ofSize: 0)
            tf.textColor = .labelColor
            tf.alignment = .center
            tf.isBezeled = false
            tf.isEditable = false
            tf.isSelectable = false
            tf.drawsBackground = false
            // 不用 Auto Layout，直接用 frame 定位
            tf.translatesAutoresizingMaskIntoConstraints = true
            self.textField = tf
            button.addSubview(tf)
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
            rootView: PopoverMenuBarView(sampler: sampler, onOpenDetails: { [weak self] in
                self?.showMainWindow()
            })
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
        showMainWindow()
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

    // MARK: - 主窗口（NSWindow + NSHostingController）

    /// 显示主窗口：已存在则激活，否则创建。打开时显示 Dock 图标。
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BatteryBar"
        window.contentMinSize = NSSize(width: 560, height: 420)
        // 记住上次窗口位置与大小；首次打开居中
        if !window.setFrameAutosaveName("BatteryBarMainWindow") {
            window.center()
        }
        // 保留窗口实例：关闭后「打开主窗口」可再次显示
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ContentView(
                usageModel: usageModel,
                cycleModel: cycleModel,
                powerModel: powerModel,
                syncModel: syncModel
            )
            .environmentObject(sampler)
            .environmentObject(syncEngine)
        )
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        // 主窗口关闭后回到纯菜单栏模式（隐藏 Dock 图标）
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
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
    /// 用 sizeToFit() 让 textField 自己计算完整渲染尺寸（含 cell padding），
    /// +2pt 余量防 % 被裁切；textField 右对齐到 button 右边缘，余量在左侧
    /// 视觉上 % 紧贴系统电池图标，左侧余量被数字前的状态栏间距吸收
    private func refreshTitle() {
        let level = Int(sampler.currentLevel)
        let text = "\(level)%"

        guard let tf = textField else { return }
        tf.stringValue = text
        tf.textColor = (level <= 20 && !sampler.currentIsCharging) ? .systemRed : .labelColor
        tf.sizeToFit()

        // sizeToFit 后 fittingSize 是 textField 完整渲染所需尺寸（含 cell padding）
        let fitWidth = tf.fittingSize.width
        let textWidth = ceil(fitWidth) + 2  // +2pt 余量防止 % 边缘被裁切

        // 固定 statusItem.length = 文字宽度 + 余量
        statusItem?.length = textWidth

        // textField 右对齐：x = 总宽度 - 文字实际渲染宽度
        // 余量出现在左侧（数字前），右侧 % 紧贴 button 右边缘
        let h = NSStatusBar.system.thickness
        let renderWidth = ceil(fitWidth)
        let x = textWidth - renderWidth
        tf.frame = NSRect(x: x, y: (h - tf.fittingSize.height) / 2, width: renderWidth, height: tf.fittingSize.height)
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
struct ContentView: View {
    @EnvironmentObject var sampler: PowerSampler
    @EnvironmentObject var syncEngine: SyncEngine
    let usageModel: UsageTabModel
    let cycleModel: CycleTabModel
    let powerModel: PowerTabModel
    let syncModel: SyncTabModel

    var body: some View {
        TabView {
            UsageTab(sampler: sampler, model: usageModel)
                .tabItem { Label("首页", systemImage: "house.fill") }

            CycleTab(model: cycleModel)
                .tabItem { Label("循环统计", systemImage: "arrow.triangle.2.circlepath") }

            PowerTab(sampler: sampler, model: powerModel)
                .tabItem { Label("组件功耗", systemImage: "bolt.fill") }

            SyncTab(syncEngine: syncEngine, model: syncModel)
                .tabItem { Label("同步", systemImage: "arrow.triangle.branch") }
        }
        .background(.thickMaterial)
    }
}

/// 状态栏弹窗
struct PopoverMenuBarView: View {
    @ObservedObject var sampler: PowerSampler
    var onOpenDetails: () -> Void

    var body: some View {
        PopoverView(sampler: sampler, onOpenDetails: onOpenDetails)
            .frame(width: 340)
    }
}
