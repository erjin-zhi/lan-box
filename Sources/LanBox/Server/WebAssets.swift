import Foundation

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

    static let favicon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#1d1d1f"/>\
    <path d="M18 25l14-7 14 7v16l-14 7-14-7z" fill="none" stroke="#fff" stroke-width="3.4" stroke-linejoin="round"/>\
    <path d="M18 25l14 7 14-7M32 32v16" fill="none" stroke="#fff" stroke-width="3.4" stroke-linejoin="round"/></svg>
    """
}
