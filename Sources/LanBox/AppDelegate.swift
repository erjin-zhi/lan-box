import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var qrPanel: NSPanel?
    private var mainWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var springLoadTask: Task<Void, Never>?
    private var pinned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        AppModel.applyDockPolicy(model.showInDock)
        NSApp.mainMenu = makeMainMenu()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.appDidBecomeActive() }
        }
        if AppModel.canNotify { UNUserNotificationCenter.current().delegate = self }
        model.requestNotificationPermission()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "LanBox — 局域网文件共享"
            // 把文件拖到菜单栏图标上即可加入共享
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        updateStatusIcon()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = PopoverView(
            model: model,
            showQR: { [weak self] in self?.showQRPanel() },
            togglePin: { [weak self] in self?.togglePinned() ?? false },
            openWindow: { [weak self] in self?.showMainWindow() },
            quit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        if let dir = ProcessInfo.processInfo.environment["LANBOX_SNAPSHOT_DIR"] {
            let delay = Double(ProcessInfo.processInfo.environment["LANBOX_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.writeSnapshots(to: URL(fileURLWithPath: dir)) }
        }

        // 显示 Dock 图标时，启动即打开主窗口；只在菜单栏时，首次启动展开面板
        if model.showInDock {
            showMainWindow()
        } else if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPopover() }
        }
        UserDefaults.standard.set(true, forKey: "launchedBefore")
    }

    // MARK: 主窗口与 Dock

    @objc func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "LanBox"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // 标题栏被内容覆盖，允许拖动空白处移动窗口
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MainWindowView(
                model: model,
                showQR: { [weak self] in self?.showQRPanel() },
                quit: { NSApp.terminate(nil) }
            ))
            window.setContentSize(NSSize(width: 980, height: 660))
            window.setFrameAutosaveName("LanBoxMainWindow")
            if !window.setFrameUsingName("LanBoxMainWindow") { window.center() }
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 点 Dock 图标：没有可见窗口时重新打开主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible != true { showMainWindow() }
        return true
    }

    /// 文件拖到 Dock 图标上，或在 Finder 里“打开方式 → LanBox”。
    func application(_ sender: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        model.add(files)
        model.flash(files.count == 1 ? "已加入“\(files[0].lastPathComponent)”" : "已加入 \(files.count) 个项目")
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 菜单与快捷键

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }

        submenu("LanBox", [
            item("关于 LanBox", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("隐藏 LanBox", #selector(NSApplication.hide(_:)), "h"),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("退出 LanBox", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("文件", [
            item("加入文件…", #selector(addFiles(_:)), "o", target: self),
            item("在 Finder 中显示共享文件夹", #selector(revealShareFolder(_:)), "r", [.command, .shift], target: self),
            .separator(),
            item("显示二维码", #selector(showQRFromMenu(_:)), "k", target: self),
            .separator(),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w"),
        ])
        // 拷贝 / 粘贴走响应链：文本框里照常编辑文字，其他地方由 AppDelegate 处理
        submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("窗口", [
            item("LanBox 主窗口", #selector(showMainWindow), "1", target: self),
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("缩放", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("前置全部窗口", #selector(NSApplication.arrangeInFront(_:))),
        ])
        if let windows = main.items.last?.submenu { NSApp.windowsMenu = windows }
        return main
    }

    /// ⌘V：把剪贴板里的文件、图片或文字加入共享。
    @objc func paste(_ sender: Any?) {
        model.pasteFromClipboard()
    }

    /// ⌘C：没有选中文字时，拷贝访问链接。
    @objc func copy(_ sender: Any?) {
        model.copyLink()
    }

    @objc private func addFiles(_ sender: Any?) { model.pickFilesToAdd() }
    @objc private func revealShareFolder(_ sender: Any?) { model.revealFolder() }
    @objc private func showQRFromMenu(_ sender: Any?) { showQRPanel() }

    // MARK: 菜单栏图标

    private func updateStatusIcon(popoverIsOpen: Bool? = nil) {
        guard let button = statusItem?.button else { return }
        let image = BoxStatusIcon.image(isOpen: popoverIsOpen ?? popover.isShown)
        if button.image !== image { button.image = image }
        button.appearsDisabled = !model.isRunning
        let online = model.onlineClients.count
        button.title = online > 0 ? " \(online)" : ""
        button.imagePosition = .imageLeading
    }

    // 跟随面板生命周期，涵盖再次点击、点外部、Esc 及程序主动展开/收起。
    func popoverWillShow(_ notification: Notification) {
        updateStatusIcon(popoverIsOpen: true)
    }

    func popoverDidShow(_ notification: Notification) {
        updateStatusIcon()
    }

    func popoverDidClose(_ notification: Notification) {
        updateStatusIcon(popoverIsOpen: false)
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate()
    }

    private func togglePinned() -> Bool {
        pinned.toggle()
        popover.behavior = pinned ? .applicationDefined : .transient
        return pinned
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        updateStatusIcon()
    }

    // MARK: 拖放到菜单栏图标（NSWindow 会把拖放消息转给 delegate）

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        model.isDropTargeted = true
        springLoadTask?.cancel()
        springLoadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { self?.showPopover() }
        }
        return .link
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .link }

    func draggingExited(_ sender: NSDraggingInfo?) {
        model.isDropTargeted = false
        springLoadTask?.cancel()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        springLoadTask?.cancel()
        model.isDropTargeted = false
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        model.add(urls)
        showPopover()
        return true
    }

    // MARK: 大二维码面板

    private func showQRPanel() {
        popover.performClose(nil)
        if let qrPanel {
            qrPanel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.contentViewController = NSHostingController(rootView: QRPanelView(model: model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        qrPanel = panel
    }

    // MARK: 调试截图（仅在设置 LANBOX_SNAPSHOT_DIR 时使用）

    private func writeSnapshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var views: [(String, AnyView)] = PopoverTab.allCases.map { tab in
            (tab.rawValue, AnyView(PopoverView(model: model, initialTab: tab, showQR: {}, togglePin: { false }, quit: {})))
        }
        views.append(("qr", AnyView(QRPanelView(model: model))))
        views.append(("main", AnyView(MainWindowView(model: model, showQR: {}, quit: {}).frame(width: 980, height: 660))))
        if ProcessInfo.processInfo.environment["LANBOX_SNAPSHOT_BURST"] != nil {
            views = [("devices", views[1].1)]
        }
        for (name, view) in views {
            let hosting = NSHostingView(rootView: view)
            hosting.frame.size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 0), size: hosting.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.backgroundColor = .windowBackgroundColor
            // 离屏渲染画不出深色模式的材质背景，截图统一用浅色
            window.appearance = NSAppearance(named: .aqua)
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            let burst = ProcessInfo.processInfo.environment["LANBOX_SNAPSHOT_BURST"] != nil
            let frames = burst ? 26 : 1
            for i in 0..<frames {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(i) * 0.3) {
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let file = burst ? String(format: "%@-%02d.png", name, i) : "\(name).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
                    if i == frames - 1 { window.orderOut(nil) }
                }
            }
        }
    }

    // MARK: 退出

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let received = model.receivedItemsInTemporaryFolder
        if !received.isEmpty {
            let alert = NSAlert()
            alert.messageText = "临时文件夹里有 \(received.count) 个收到的文件"
            alert.informativeText = "退出后系统可能会清理临时文件夹。要把这些文件移到“下载”文件夹吗？"
            alert.addButton(withTitle: "移到“下载”并退出")
            alert.addButton(withTitle: "直接退出")
            alert.addButton(withTitle: "取消")
            NSApp.activate()
            switch alert.runModal() {
            case .alertFirstButtonReturn: model.moveReceivedToDownloads()
            case .alertSecondButtonReturn: break
            default: return .terminateCancel
            }
        }
        model.stopSharing()
        return .terminateNow
    }

    // MARK: 通知

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.model.showInDock ? self.showMainWindow() : self.showPopover() }
    }
}
