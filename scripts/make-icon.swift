// 由 Resources/web/logo.svg 生成 macOS App 图标、网页 touch icon 和预览图。
// 用法：swift scripts/make-icon.swift <输出目录>
//
// 小尺寸做了光学调整：32 px 及以下加粗线条，16 px 去掉外圈信号和侧面明暗，保证在 Finder 列表里也清晰。
import AppKit

let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
let master = try String(contentsOf: project.appendingPathComponent("Resources/web/logo.svg"), encoding: .utf8)

/// 按像素尺寸调整 SVG：线宽随尺寸变化，最小尺寸去掉细节。
func svg(forPixels px: Int) -> String {
    var s = master
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

func bitmap(_ px: Int, draw: (CGContext, CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    draw(ctx, CGRect(x: 0, y: 0, width: px, height: px))
    return rep.representation(using: .png, properties: [:])!
}

func artwork(_ px: Int) -> NSImage { NSImage(data: Data(svg(forPixels: px).utf8))! }

/// macOS 图标：按系统模板四周留 9.8%，加一层紧凑投影。
func macIcon(_ px: Int) -> Data {
    bitmap(px) { ctx, rect in
        let side = CGFloat(px)
        let tile = rect.insetBy(dx: side * 0.098, dy: side * 0.098)
        let art = artwork(Int(tile.width.rounded()))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.01), blur: side * 0.02,
                      color: NSColor.black.withAlphaComponent(0.28).cgColor)
        art.draw(in: tile)
        ctx.restoreGState()
    }
}

/// iOS 主屏图标会自己裁圆角，需要不透明的满版方图。
func touchIcon(_ px: Int) -> Data {
    bitmap(px) { ctx, rect in
        ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.19, blue: 0.21, alpha: 1).cgColor)
        ctx.fill(rect)
        let s = svg(forPixels: px)
            .replacingOccurrences(of: #"rx="14.4""#, with: #"rx="0""#)
            .replacingOccurrences(of: #"<rect id="rim"[^>]*/>"#, with: "", options: .regularExpression)
        NSImage(data: Data(s.utf8))!.draw(in: rect)
    }
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try macIcon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try macIcon(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try macIcon(1024).write(to: out.appendingPathComponent("AppIcon.png"))
try touchIcon(180).write(to: out.appendingPathComponent("touch-icon.png"))
print("ok")
