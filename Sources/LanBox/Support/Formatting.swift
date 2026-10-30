import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(Int(seconds)) 秒前" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm:ss"
        return "加入时间：" + f.string(from: date)
    }

    static func remaining(done: Int64, total: Int64, speed: Double) -> String? {
        guard speed > 1, total > done else { return nil }
        let s = Double(total - done) / speed
        if s < 60 { return "约 \(max(1, Int(s))) 秒" }
        if s < 3600 { return "约 \(Int(s / 60)) 分钟" }
        return "约 \(Int(s / 3600)) 小时"
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 16, y: 16)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 16, height: output.extent.height / 16))
    }
}

extension URL {
    var isSymlink: Bool {
        (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}
