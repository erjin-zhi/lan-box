import AppKit

/// A fixed box body with folding lids; transparent monochrome images for NSStatusItem.
@MainActor
enum BoxStatusIcon {
    static let closed = make(open: false)
    static let open = make(open: true)

    static func image(isOpen: Bool) -> NSImage { isOpen ? open : closed }

    private static func make(open: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
            NSColor.black.setStroke()
            func stroke(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
                let path = NSBezierPath()
                path.lineWidth = 1.35
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                guard let first = points.first else { return }
                path.move(to: NSPoint(x: first.0, y: first.1))
                for point in points.dropFirst() {
                    path.line(to: NSPoint(x: point.0, y: point.1))
                }
                if close { path.close() }
                path.stroke()
            }
            stroke([(5, 9), (11, 6), (17, 9), (17, 16), (11, 19), (5, 16)], close: true)
            stroke([(5, 9), (11, 12), (17, 9)])
            stroke([(11, 12), (11, 19)])
            if open {
                stroke([(5, 9), (2, 6), (8, 3), (11, 6), (14, 3), (20, 6), (17, 9)])
            } else {
                // Tape crosses the top and turns down the front-right face.
                stroke([(8, 7.5), (14, 10.5), (14, 13)])
            }
            return true
        }
        image.isTemplate = true
        image.setName(open ? "LanBox.MenuBar.Open" : "LanBox.MenuBar.Closed")
        image.accessibilityDescription = open ? "LanBox，共享面板已打开" : "LanBox，共享面板已关闭"
        return image
    }
}
