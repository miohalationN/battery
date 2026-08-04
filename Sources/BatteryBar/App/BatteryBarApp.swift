import SwiftUI
import AppKit

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口 — WindowGroup 配合单例控制，避免反复 openWindow 创建多窗口
        // sampler / syncEngine 由 AppDelegate 持有，状态栏/主窗口/popover 共用同一实例
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.syncEngine)
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
        .defaultSize(width: 760, height: 580)
    }

    init() {
        // 设置 App 图标（运行时绘制，无需外部资源）
        NSApplication.shared.applicationIconImage = Self.drawAppIcon()

        // 启动标记（确认 app 重启）
        try? "BatteryBar started at \(Date())".write(toFile: "/tmp/batterybar_started.txt",
                                                       atomically: true, encoding: .utf8)
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

/// AppDelegate — 精确控制状态栏宽度，消除系统 padding
/// 用固定 statusItem.length = 文字实际渲染宽度，绕过 NSStatusBarButton 的内置 padding
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    let sampler = PowerSampler()
    let syncEngine = SyncEngine()
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
            button.action = #selector(togglePopover(_:))

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

        // 监听 sampler 变化，更新文字
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PowerSamplerDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshTitle()
        }

        // 创建 popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverMenuBarView(sampler: sampler))
        self.popover = popover

        // 延迟触发一次刷新（等 sampler 第一次采样完成）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshTitle()
        }
    }

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
    /// 用 sizeToFit() 让 textField 自己计算完整渲染尺寸（含 cell padding），
    /// +2pt 余量防 % 被裁切；textField 右对齐到 button 右边缘，余量在左侧
    /// 视觉上 % 紧贴系统电池图标，左侧余量被数字前的状态栏间距吸收
    @MainActor
    private func refreshTitle() {
        let level = Int(sampler.currentLevel)
        let text = "\(level)%"

        guard let tf = textField else { return }
        tf.stringValue = text
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
        .background(.thickMaterial)
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
