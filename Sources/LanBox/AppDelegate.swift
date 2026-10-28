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
    private var cancellables: Set<AnyCancellable> = []
    private var springLoadTask: Task<Void, Never>?
    private var pinned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.writeSnapshots(to: URL(fileURLWithPath: dir)) }
        }

        // 首次启动直接展示面板，告诉用户服务已经就绪
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showPopover() }
        }
    }

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
        await MainActor.run { self.showPopover() }
    }
}
