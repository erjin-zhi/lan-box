import AppKit
import QuartzCore
import XCTest
@testable import LanBox

final class MenuBarDropPanelTests: XCTestCase {
    func testNativeDestinationOwnsTheArtworkAndOuterPadding() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let panel = MenuBarDropPanel(state: MenuBarDropState())
            defer { panel.orderOut(nil) }
            let destination = try XCTUnwrap(panel.contentView)

            XCTAssertEqual(destination.bounds.size, MenuBarDropGeometry.panelSize)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertFalse(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)

            for point in Self.destinationPoints(in: destination.bounds) {
                let parentPoint = destination.convert(point, to: destination.superview)
                XCTAssertTrue(destination.hitTest(parentPoint) === destination,
                              "Both the artwork and its padding must hit the native drop receiver at \(point)")
            }
            XCTAssertNil(destination.hitTest(NSPoint(x: -1, y: -1)))
            XCTAssertTrue(destination.registeredDraggedTypes.contains(.fileURL))
        }
    }

    func testWindowAndViewBothImplementTheDropCallbacks() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let panel = MenuBarDropPanel(state: MenuBarDropState())
            defer { panel.orderOut(nil) }
            let destination = try XCTUnwrap(panel.contentView)

            for selector in ["draggingEntered:", "draggingUpdated:", "prepareForDragOperation:",
                             "performDragOperation:", "draggingExited:", "draggingEnded:"] {
                XCTAssertTrue(panel.responds(to: NSSelectorFromString(selector)),
                              "The window must accept drag callbacks independently of SwiftUI: \(selector)")
                XCTAssertTrue(destination.responds(to: NSSelectorFromString(selector)))
            }
        }
    }

    /// This checks WindowServer routing, rather than only AppKit view hit testing.
    /// It creates two small nonactivating windows and never synthesizes user input.
    func testFirstVisibleFrameBlocksTheUnderlyingWindowIncludingPadding() async throws {
        try await MainActor.run {
            let app = NSApplication.shared
            let originalPolicy = app.activationPolicy()
            // SwiftPM's command-line XCTest runner starts as a prohibited app.
            // Give only this smoke test the same window-ordering ability as the
            // menu-bar app, without activating it or taking keyboard focus.
            if originalPolicy == .prohibited {
                guard app.setActivationPolicy(.accessory) else {
                    throw XCTSkip("The test runner cannot enable nonactivating AppKit windows")
                }
            }
            defer {
                if app.activationPolicy() != originalPolicy { app.setActivationPolicy(originalPolicy) }
            }
            guard let screen = NSScreen.main else {
                throw XCTSkip("WindowServer smoke check requires a graphical macOS session")
            }
            let size = MenuBarDropGeometry.panelSize
            let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                               y: screen.visibleFrame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let underlying = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            underlying.isReleasedWhenClosed = false
            underlying.backgroundColor = .windowBackgroundColor
            underlying.isOpaque = true
            underlying.ignoresMouseEvents = false
            underlying.level = .popUpMenu
            underlying.hidesOnDeactivate = false
            underlying.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            underlying.animationBehavior = .none

            let panel = MenuBarDropPanel(state: MenuBarDropState())
            panel.setFrame(frame, display: false)
            defer {
                panel.orderOut(nil)
                underlying.orderOut(nil)
            }

            underlying.display()
            underlying.orderFrontRegardless()
            let points = Self.destinationPoints(in: NSRect(origin: .zero, size: size))
                .map { NSPoint(x: frame.minX + $0.x, y: frame.minY + $0.y) }

            // WindowServer may not yet know a newly promoted XCTest process.
            // Settle only the opaque lower-window baseline, not the drop panel.
            app.updateWindows()
            let baselineDeadline = Date(timeIntervalSinceNow: 0.2)
            var baselineHits = points.map { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
            while !baselineHits.allSatisfy({ $0 == underlying.windowNumber }), Date() < baselineDeadline {
                RunLoop.current.run(until: min(Date(timeIntervalSinceNow: 0.01), baselineDeadline))
                baselineHits = points.map { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
            }
            guard baselineHits.allSatisfy({ $0 == underlying.windowNumber }) else {
                XCTFail("Cannot establish opaque WindowServer baseline after 200ms: expected \(underlying.windowNumber), got \(baselineHits); visible=\(underlying.isVisible), policy=\(app.activationPolicy().rawValue)")
                return
            }

            panel.contentView?.layoutSubtreeIfNeeded()
            panel.display()
            panel.orderFrontRegardless()
            app.updateWindows()
            CATransaction.flush()
            // Present the submitted surface once. This is far shorter than the
            // removed 160ms fade and does not wait for the artwork animation.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            XCTAssertTrue(panel.isVisible)

            // Check the first presented frame, including the 10pt gutter; do not
            // retry a miss until an opacity or artwork animation has finished.
            for point in points {
                let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                XCTAssertEqual(hit, panel.windowNumber,
                               "The visible drop panel must intercept \(point); underlying window is \(underlying.windowNumber)")
                XCTAssertNotEqual(hit, underlying.windowNumber)
            }
        }
    }

    private static func destinationPoints(in bounds: NSRect) -> [NSPoint] {
        [NSPoint(x: bounds.midX, y: bounds.midY),
         NSPoint(x: bounds.minX + 2, y: bounds.minY + 2),
         NSPoint(x: bounds.maxX - 2, y: bounds.minY + 2),
         NSPoint(x: bounds.minX + 2, y: bounds.maxY - 2),
         NSPoint(x: bounds.maxX - 2, y: bounds.maxY - 2),
         NSPoint(x: bounds.midX, y: bounds.minY + 5),
         NSPoint(x: bounds.minX + 5, y: bounds.midY)]
    }
}
