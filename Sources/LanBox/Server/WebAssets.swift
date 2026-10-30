import AppKit

enum WebAssets {
    /// 打包后从 App 的 Resources 读取；用 `swift run` 开发时直接读源码目录，改完网页刷新即可。
    private static let sourceWebDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/web")

    private static let bundledIndex: Data? = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
        .flatMap { try? Data(contentsOf: $0) }

    static func indexHTML() -> Data {
        if let bundledIndex { return bundledIndex }
        return (try? Data(contentsOf: sourceWebDir.appendingPathComponent("index.html")))
            ?? Data("<h1>LanBox</h1><p>网页资源缺失。</p>".utf8)
    }

    static let touchIcon: Data = {
        if let url = Bundle.main.url(forResource: "touch-icon", withExtension: "png", subdirectory: "web"),
           let data = try? Data(contentsOf: url) { return data }
        return (try? Data(contentsOf: sourceWebDir.appendingPathComponent("touch-icon.png"))) ?? Data()
    }()

    // MARK: 标志

    /// Resources/web/logo.svg：App 图标、App 内标志、网页标志和 favicon 的唯一来源。
    static let logoMaster: String = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "svg", subdirectory: "web"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return (try? String(contentsOf: sourceWebDir.appendingPathComponent("logo.svg"), encoding: .utf8)) ?? ""
    }()

    /// 按显示像素做光学调整（与 scripts/make-icon.swift 同一套规则）：小尺寸加粗线条、去掉外圈信号。
    static func logoSVG(forPixels px: Int) -> String {
        var s = logoMaster
        let stroke: String
        switch px {
        case ...16: stroke = "5.8"
        case ...32: stroke = "4.6"
        case ...64: stroke = "3.6"
        case ...128: stroke = "3.2"
        default: stroke = "2.9"
        }
        s = s.replacingOccurrences(of: "stroke-width=\"2.9\"", with: "stroke-width=\"\(stroke)\"")
        if px <= 16 {
            s = s.replacingOccurrences(of: #"<path id="arc-outer"[^>]*/>"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"<g id="faces">[\s\S]*?</g>"#, with: "", options: .regularExpression)
        }
        return s
    }

    /// 浏览器标签页上只有 16–32 px，用加粗版本。
    static let favicon = logoSVG(forPixels: 32)

    @MainActor private static var logoCache: [Int: NSImage] = [:]

    /// App 内标志（按点尺寸取图，内部按 2 倍像素做光学调整）。
    @MainActor static func logoImage(points: CGFloat) -> NSImage {
        let px = Int((points * 2).rounded())
        if let cached = logoCache[px] { return cached }
        let image = NSImage(data: Data(logoSVG(forPixels: px).utf8)) ?? NSImage()
        image.size = NSSize(width: points, height: points)
        logoCache[px] = image
        return image
    }
}
