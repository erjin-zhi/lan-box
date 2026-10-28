import Foundation

enum DeviceKind: String, Codable {
    case phone, tablet, laptop, desktop, unknown
}

/// 从 User-Agent 推断出的设备信息。浏览器端的 hello 请求可以覆盖其中的类型与名称。
struct DeviceProfile {
    var kind: DeviceKind
    var platform: String
    var browser: String
    var defaultName: String

    init(userAgent ua: String) {
        let lower = ua.lowercased()
        switch true {
        case ua.contains("iPhone"):
            kind = .phone; platform = "iOS"; defaultName = "iPhone"
        case ua.contains("iPad"):
            kind = .tablet; platform = "iPadOS"; defaultName = "iPad"
        case ua.contains("Android"):
            let mobile = ua.contains("Mobile")
            kind = mobile ? .phone : .tablet
            platform = "Android"
            defaultName = DeviceProfile.androidModel(ua) ?? (mobile ? "Android 手机" : "Android 平板")
        case ua.contains("CrOS"):
            kind = .laptop; platform = "ChromeOS"; defaultName = "Chromebook"
        case ua.contains("Macintosh"):
            kind = .laptop; platform = "macOS"; defaultName = "Mac"
        case ua.contains("Windows"):
            kind = .desktop; platform = "Windows"; defaultName = "Windows 电脑"
        case lower.contains("linux"):
            kind = .desktop; platform = "Linux"; defaultName = "Linux 电脑"
        case lower.hasPrefix("curl") || lower.hasPrefix("wget"):
            kind = .desktop; platform = "命令行"; defaultName = "命令行客户端"
        default:
            kind = .unknown; platform = "未知系统"; defaultName = "未知设备"
        }

        switch true {
        case ua.contains("MicroMessenger"): browser = "微信"
        case ua.contains("DingTalk"): browser = "钉钉"
        case ua.contains("Lark") || ua.contains("Feishu"): browser = "飞书"
        case ua.contains("QQBrowser") || ua.contains(" QQ/"): browser = "QQ"
        case ua.contains("Edg"): browser = "Edge"
        case ua.contains("Firefox") || ua.contains("FxiOS"): browser = "Firefox"
        case ua.contains("CriOS") || ua.contains("Chrome"): browser = "Chrome"
        case ua.contains("Safari"): browser = "Safari"
        case lower.hasPrefix("curl"): browser = "curl"
        default: browser = "浏览器"
        }
    }

    private static func androidModel(_ ua: String) -> String? {
        // "Linux; Android 14; Pixel 8 Build/..." → "Pixel 8"
        guard let range = ua.range(of: "Android ") else { return nil }
        let tail = ua[range.upperBound...]
        let parts = tail.split(separator: ";", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        var model = parts[1]
        if let end = model.firstIndex(where: { $0 == ")" }) { model = String(model[..<end]) }
        if let build = model.range(of: " Build") { model = String(model[..<build.lowerBound]) }
        model = model.trimmingCharacters(in: .whitespaces)
        return model.count > 2 && model != "wv" ? model : nil
    }
}

extension DeviceKind {
    func symbol(platform: String) -> String {
        switch self {
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .laptop: return platform == "macOS" ? "laptopcomputer" : "laptopcomputer"
        case .desktop: return platform == "Windows" ? "pc" : "desktopcomputer"
        case .unknown: return "questionmark.app.dashed"
        }
    }
}
