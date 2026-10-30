import AppKit
import XCTest
@testable import LanBox

final class MenuBarDropTests: XCTestCase {
    func testMovingAWindowDoesNotReuseFilesLeftByAnEarlierDrag() {
        var session = MenuBarFileDragSession(changeCount: 41)
        session.begin(changeCount: 41)

        // Finder retains the last file URLs after a drop. A new mouse gesture
        // with that unchanged pasteboard must not reveal the file destination.
        session.observe(changeCount: 41, fileCount: 3)
        XCTAssertEqual(session.fileCount, 0)

        session.observe(changeCount: 42, fileCount: 3)
        XCTAssertEqual(session.fileCount, 3)
    }

    func testNewNonFilePasteboardContentsDoNotOpenTheBox() {
        var session = MenuBarFileDragSession(changeCount: 8)
        session.begin(changeCount: 8)
        session.observe(changeCount: 9, fileCount: 0)
        XCTAssertEqual(session.fileCount, 0)

        // A source may populate the pasteboard after the drag has started.
        session.observe(changeCount: 10, fileCount: 2)
        XCTAssertEqual(session.fileCount, 2)
    }

    func testCompletedDragCannotReviveUntilAnotherMouseGesture() {
        var session = MenuBarFileDragSession(changeCount: 20)
        session.begin(changeCount: 20)
        session.observe(changeCount: 21, fileCount: 1)
        XCTAssertEqual(session.fileCount, 1)

        session.finish()
        session.observe(changeCount: 22, fileCount: 1)
        session.confirm(fileCount: 1)
        XCTAssertEqual(session.fileCount, 0, "Late tracking or destination callbacks must not reopen a completed drag")
        XCTAssertTrue(session.isFinished)

        session.begin(changeCount: 22)
        session.observe(changeCount: 22, fileCount: 1)
        XCTAssertEqual(session.fileCount, 0, "A new mouse-down still must not reuse the previous pasteboard")
        session.observe(changeCount: 23, fileCount: 4)
        XCTAssertEqual(session.fileCount, 4)
        XCTAssertFalse(session.isFinished)
    }

    func testBoxRemainsOnTheNegativeCoordinateDisplay() {
        let screen = NSRect(x: -1920, y: -300, width: 1920, height: 1056)
        let icon = NSRect(x: -980, y: screen.maxY, width: 24, height: 24)
        let frame = MenuBarDropGeometry.panelFrame(anchor: icon, visibleFrame: screen)

        XCTAssertEqual(frame.midX, icon.midX, accuracy: 0.01)
        XCTAssertLessThan(frame.maxX, 0, "The destination belongs on the icon's display, not the main display")
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThan(frame.minY, icon.minY)
        // The transparent top margin may overlap the menu bar slightly.
        XCTAssertLessThanOrEqual(frame.maxY, icon.minY + 2)
    }

    func testBoxClampsAtTheRightEdgeWithoutLosingItsDropArea() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 876),
                       NSRect(x: -1920, y: -300, width: 1920, height: 1056)] {
            let icon = NSRect(x: screen.maxX - 28, y: screen.maxY, width: 24, height: 24)
            let frame = MenuBarDropGeometry.panelFrame(anchor: icon, visibleFrame: screen)

            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
            XCTAssertEqual(frame.size, MenuBarDropGeometry.panelSize, "Edge placement must preserve the usable drop target")
            XCTAssertTrue((frame.minX...frame.maxX).contains(icon.midX))
        }
    }

    func testSourceThatCannotLinkFallsBackToCopy() {
        XCTAssertEqual(MenuBarDropGeometry.operation(preferCopy: false, allowed: [.copy, .move]), .copy)
        XCTAssertEqual(MenuBarDropGeometry.operation(preferCopy: false, allowed: [.link, .copy, .move]), .link)
        XCTAssertEqual(MenuBarDropGeometry.operation(preferCopy: true, allowed: [.link, .copy, .move]), .copy)
        XCTAssertEqual(MenuBarDropGeometry.operation(preferCopy: true, allowed: [.link]), .link)
    }

    func testMoveOnlyDragIsRejectedSoTheSourceIsNeverDeleted() {
        for preferCopy in [false, true] {
            for allowed: NSDragOperation in [[], .move, [.move, .generic], .delete] {
                XCTAssertTrue(MenuBarDropGeometry.operation(preferCopy: preferCopy, allowed: allowed).isEmpty)
            }
            XCTAssertFalse(MenuBarDropGeometry.operation(preferCopy: preferCopy, allowed: .every).contains(.move))
        }
    }
}
