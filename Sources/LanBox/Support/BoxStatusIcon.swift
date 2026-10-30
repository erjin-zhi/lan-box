import AppKit

/// 菜单栏图标：与 App 标志（Resources/web/logo.svg）同一个线条盒，单色 template。
/// 面板收起时是盒子和信号点；面板展开时多一道信号弧，表示正在对外展示。
@MainActor
enum BoxStatusIcon {
    static let closed = make(open: false)
    static let open = make(open: true)

    static func image(isOpen: Bool) -> NSImage { isOpen ? open : closed }

    private static func make(open: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
            // logo.svg 用 64 单位网格；缩放到 22 pt 并居中
            let k: CGFloat = 0.43
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: (x - 32) * k + 11, y: (y - 31.3) * k + 11.4) }
            NSColor.black.setStroke()
            NSColor.black.setFill()
            func stroke(_ points: [(CGFloat, CGFloat)], close: Bool = false) {
                let path = NSBezierPath()
                path.lineWidth = 1.35
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                guard let first = points.first else { return }
                path.move(to: p(first.0, first.1))
                for point in points.dropFirst() { path.line(to: p(point.0, point.1)) }
                if close { path.close() }
                path.stroke()
            }
            stroke([(14, 25.5), (32, 16.5), (50, 25.5), (32, 34.5)], close: true)
            stroke([(14, 25.5), (14, 41.5), (32, 50.5), (50, 41.5), (50, 25.5)])
            stroke([(32, 34.5), (32, 50.5)])

            let c = p(32, 27)
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.15, y: c.y - 1.15, width: 2.3, height: 2.3)).fill()
            if open {
                // flipped 坐标里，向上的弧是从 225° 到 315°
                let arc = NSBezierPath()
                arc.lineWidth = 1.35
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: c, radius: 15 * k, startAngle: 225, endAngle: 315, clockwise: false)
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.setName(open ? "LanBox.MenuBar.Open" : "LanBox.MenuBar.Closed")
        image.accessibilityDescription = open ? "LanBox，共享面板已打开" : "LanBox，共享面板已关闭"
        return image
    }
}
