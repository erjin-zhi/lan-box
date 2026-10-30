import AppKit
import SwiftUI

/// Only a fresh drag pasteboard belongs to the current mouse gesture. Finder leaves
/// old file URLs on it after a drop; those must not turn a window move into a file drag.
struct MenuBarFileDragSession {
    private(set) var baseline: Int
    private(set) var isFinished = false
    private(set) var fileCount = 0

    init(changeCount: Int) { baseline = changeCount }

    mutating func begin(changeCount: Int) {
        baseline = changeCount
        isFinished = false
        fileCount = 0
    }

    mutating func observe(changeCount: Int, fileCount: Int) {
        guard !isFinished, changeCount != baseline else { return }
        self.fileCount = fileCount
    }

    mutating func confirm(fileCount: Int) {
        guard !isFinished else { return }
        self.fileCount = fileCount
    }

    mutating func finish() {
        isFinished = true
        fileCount = 0
    }
}

enum MenuBarDropGeometry {
    static let panelSize = NSSize(width: 264, height: 232)

    static func approachRect(for anchor: NSRect) -> NSRect {
        NSRect(x: anchor.minX - 64, y: anchor.minY - 82,
               width: anchor.width + 128, height: anchor.height + 82)
    }

    static func panelFrame(anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let x = min(max(anchor.midX - panelSize.width / 2, visibleFrame.minX + 8),
                    visibleFrame.maxX - panelSize.width - 8)
        let top = min(anchor.minY + 2, visibleFrame.maxY + 2)
        return NSRect(x: x, y: max(visibleFrame.minY, top - panelSize.height),
                      width: panelSize.width, height: panelSize.height)
    }

    static func operation(preferCopy: Bool, allowed: NSDragOperation) -> NSDragOperation {
        for operation: NSDragOperation in preferCopy ? [.copy, .link] : [.link, .copy] {
            if allowed.contains(operation) { return operation }
        }
        // Never advertise a move: LanBox does not remove the source file.
        return []
    }
}

/// Shows a spring-loaded destination without activating LanBox or disturbing Finder.
@MainActor
final class MenuBarDropController {
    let state = MenuBarDropState()
    private weak var button: NSStatusBarButton?
    private let preferCopy: () -> Bool
    private let onVisibilityChange: (Bool) -> Void
    private let onDrop: ([URL]) -> Void
    private let onComplete: () -> Void
    private var panel: MenuBarDropPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trackingTimer: Timer?
    private var finishTask: Task<Void, Never>?
    private var receiptTask: Task<Void, Never>?
    private let pasteboard = NSPasteboard(name: .drag)
    private var session: MenuBarFileDragSession
    private var lastReadChangeCount: Int?
    private var outsideSince: Date?

    init(button: NSStatusBarButton, preferCopy: @escaping () -> Bool,
         onVisibilityChange: @escaping (Bool) -> Void,
         onDrop: @escaping ([URL]) -> Void, onComplete: @escaping () -> Void) {
        self.button = button
        self.preferCopy = preferCopy
        self.onVisibilityChange = onVisibilityChange
        self.onDrop = onDrop
        self.onComplete = onComplete
        session = MenuBarFileDragSession(changeCount: pasteboard.changeCount)
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        finishTask?.cancel()
        receiptTask?.cancel()
        hide()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            finishTask?.cancel()
            finishTask = nil
            receiptTask?.cancel()
            receiptTask = nil
            hide()
            state.isReceiving = false
            session.begin(changeCount: pasteboard.changeCount)
            lastReadChangeCount = nil
        case .leftMouseDragged:
            guard !session.isFinished else { return }
            startTracking()
            track()
        case .leftMouseUp:
            finishAfterMouseUp()
        default: break
        }
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func track() {
        guard !session.isFinished else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finishAfterMouseUp()
            return
        }
        let changeCount = pasteboard.changeCount
        if changeCount != lastReadChangeCount {
            session.observe(changeCount: changeCount, fileCount: Self.files(on: pasteboard).count)
            lastReadChangeCount = changeCount
        }
        guard session.fileCount > 0, let (anchor, screen) = anchor() else {
            hide()
            return
        }
        let point = NSEvent.mouseLocation
        let approach = MenuBarDropGeometry.approachRect(for: anchor)
        if approach.contains(point) {
            outsideSince = nil
            show(anchor: anchor, screen: screen)
        } else if let panel, panel.isVisible {
            if panel.frame.insetBy(dx: -24, dy: -20).contains(point) {
                outsideSince = nil
            } else if let outsideSince {
                if Date().timeIntervalSince(outsideSince) > 0.18 { hide() }
            } else {
                outsideSince = Date()
            }
        }
    }

    private func anchor() -> (NSRect, NSScreen)? {
        guard let button, let window = button.window, window.isVisible,
              let screen = window.screen else { return nil }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(rect), rect.width > 0 else { return nil }
        return (rect, screen)
    }

    private func show(anchor: NSRect, screen: NSScreen) {
        if panel == nil {
            panel = MenuBarDropPanel(state: state, controller: self)
        }
        guard let panel else { return }
        state.fileCount = session.fileCount
        let frame = MenuBarDropGeometry.panelFrame(anchor: anchor, visibleFrame: screen.visibleFrame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        guard !panel.isVisible else { return }
        state.isReceiving = false
        // A transparent window is not a reliable drag destination. Keep the
        // native surface hit-testable from its first frame; animate only artwork.
        panel.alphaValue = 1
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.display()
        panel.orderFrontRegardless()
        onVisibilityChange(true)
    }

    private func hide() {
        outsideSince = nil
        state.isTargeted = false
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        onVisibilityChange(false)
    }

    // Mouse-up can be observed before AppKit delivers performDragOperation. Keep
    // the destination alive briefly so releasing over the box cannot lose a file.
    private func finishAfterMouseUp() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        guard finishTask == nil, !state.isReceiving else { return }
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.session.finish()
            self.hide()
            self.finishTask = nil
        }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = Self.files(on: sender.draggingPasteboard)
        let operation = MenuBarDropGeometry.operation(preferCopy: preferCopy(), allowed: sender.draggingSourceOperationMask)
        guard !files.isEmpty, !operation.isEmpty, !session.isFinished else {
            state.isTargeted = false
            return []
        }
        session.confirm(fileCount: files.count)
        finishTask?.cancel()
        finishTask = nil
        if let (anchor, screen) = anchor() { show(anchor: anchor, screen: screen) }
        state.isTargeted = true
        startTracking()
        return operation
    }

    func draggingExited() {
        state.isTargeted = false
        // The cursor may simply be crossing from the icon into the box.
        track()
    }

    func draggingEnded() {
        if !state.isReceiving {
            session.finish()
            finishAfterMouseUp()
        }
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = Self.files(on: sender.draggingPasteboard)
        guard !files.isEmpty, !session.isFinished,
              !MenuBarDropGeometry.operation(preferCopy: preferCopy(), allowed: sender.draggingSourceOperationMask).isEmpty else { return false }
        finishTask?.cancel()
        finishTask = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        session.finish()
        state.fileCount = files.count
        state.isReceiving = true
        onDrop(files)
        receiptTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled, let self else { return }
            self.hide()
            self.onComplete()
            self.receiptTask = nil
        }
        return true
    }

    private static func files(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

@MainActor
final class MenuBarDropPanel: NSPanel, NSDraggingDestination {
    private weak var controller: MenuBarDropController?

    init(state: MenuBarDropState, controller: MenuBarDropController? = nil) {
        self.controller = controller
        super.init(contentRect: NSRect(origin: .zero, size: MenuBarDropGeometry.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        // Back the entire destination, including the padding around the artwork.
        // A clear backing plus SwiftUI material can leave WindowServer hit-test holes.
        backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.08)
        ignoresMouseEvents = false
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        animationBehavior = .none
        let destination = DropDestinationView(frame: NSRect(origin: .zero, size: MenuBarDropGeometry.panelSize))
        destination.controller = controller
        let hosting = NSHostingView(rootView: MenuBarDropView(state: state))
        hosting.frame = destination.bounds
        hosting.autoresizingMask = [.width, .height]
        destination.addSubview(hosting)
        contentView = destination
        registerForDraggedTypes([.fileURL])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // NSWindow also receives drags, so SwiftUI subview hit testing cannot route
    // a file to another app underneath this visible panel.
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.draggingEntered(sender) ?? [] }
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.draggingEntered(sender) ?? [] }
    func draggingExited(_ sender: NSDraggingInfo?) { controller?.draggingExited() }
    func draggingEnded(_ sender: NSDraggingInfo) { controller?.draggingEnded() }
    func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller != nil }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDragOperation(sender) ?? false }
}

@MainActor
private final class DropDestinationView: NSView {
    weak var controller: MenuBarDropController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("LanBox 文件投放盒")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Render the card in AppKit as well, before the hosted view's first frame.
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 10), xRadius: 24, yRadius: 24).fill()
    }

    // The SwiftUI artwork is decorative; AppKit owns the whole drop target.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.draggingEntered(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.draggingExited() }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.draggingEnded() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDragOperation(sender) ?? false }
}
