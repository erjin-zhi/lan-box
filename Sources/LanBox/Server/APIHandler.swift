import AppKit
import Foundation
import QuickLookThumbnailing

/// 把 HTTP 请求路由到具体功能：网页、列表、下载、上传、缩略图、实时事件。
final class APIHandler: @unchecked Sendable {
    let hub: ServerHub
    private let lock = NSLock()
    private var _store: ShareStore
    private let thumbCache = NSCache<NSString, NSData>()

    init(hub: ServerHub, store: ShareStore) {
        self.hub = hub
        self._store = store
        thumbCache.countLimit = 600
    }

    var store: ShareStore {
        get { lock.withLock { _store } }
        set { lock.withLock { _store = newValue } }
    }

    // MARK: 入口

    func handle(_ req: HTTPRequest, _ c: HTTPConnection) {
        var extraHeaders: [(String, String)] = []
        var clientID = req.cookies["lb_dev"] ?? ""
        if clientID.count < 8 || clientID.count > 64 || !clientID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
            clientID = UUID().uuidString.lowercased()
            extraHeaders.append(("Set-Cookie", "lb_dev=\(clientID); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"))
        }

        if hub.isBlocked(clientID, ip: c.remoteIP) {
            c.respondError(403, "此设备已被 Mac 端阻止访问")
            return
        }

        let cfg = hub.config
        var authorized = !cfg.requirePIN || req.cookies["lb_key"] == cfg.pin
        if !authorized, let k = req.query["k"], k == cfg.pin {
            authorized = true
            extraHeaders.append(("Set-Cookie", keyCookie(cfg.pin)))
        }

        let isPage = req.path == "/" || req.path == "/index.html"
        if isPage || (req.path.hasPrefix("/api/") && req.path != "/api/ping" && req.path != "/api/bye") {
            hub.touch(id: clientID, ip: c.remoteIP, userAgent: req.userAgent, authorized: authorized)
        }

        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            servePage(c, headers: extraHeaders)
            return
        case ("GET", "/logo.svg"):
            c.respond(HTTPHead(200, [("Content-Type", "image/svg+xml"), ("Cache-Control", "max-age=3600")]), body: Data(WebAssets.logoMaster.utf8))
            return
        case ("GET", "/favicon.svg"), ("GET", "/favicon.ico"):
            var head = HTTPHead(200, [("Content-Type", "image/svg+xml"), ("Cache-Control", "max-age=86400")])
            head.headers += extraHeaders
            c.respond(head, body: Data(WebAssets.favicon.utf8))
            return
        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"):
            c.respond(HTTPHead(200, [("Content-Type", "image/png"), ("Cache-Control", "max-age=86400")]), body: WebAssets.touchIcon)
            return
        case ("POST", "/api/auth"):
            handleAuth(req, c, clientID: clientID)
            return
        case ("POST", "/api/ping"):
            readJSON(req, c, limit: 1024) { [self] (body: [String: Bool]?) in
                hub.heartbeat(id: clientID, ip: c.remoteIP, userAgent: req.userAgent, authorized: authorized, visible: body?["visible"] ?? true)
                c.respondJSON(200, ["ok": "1"], headers: extraHeaders)
            }
            return
        case ("POST", "/api/bye"):
            readJSON(req, c, limit: 1024) { [self] (_: [String: Bool]?) in
                hub.bye(id: clientID)
                c.respond(HTTPHead(204), body: Data())
            }
            return
        default:
            break
        }

        guard authorized else {
            c.respondJSON(401, ["error": "需要访问码", "needPin": "1"], headers: extraHeaders)
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/api/info"): handleInfo(c, clientID: clientID, headers: extraHeaders)
        case ("POST", "/api/hello"): handleHello(req, c, clientID: clientID)
        case ("GET", "/api/list"): handleList(req, c, clientID: clientID)
        case ("GET", "/api/download"), ("HEAD", "/api/download"): handleDownload(req, c, clientID: clientID)
        case ("GET", "/api/thumb"): handleThumb(req, c)
        case ("PUT", "/api/upload"), ("POST", "/api/upload"): handleUpload(req, c, clientID: clientID)
        case ("GET", "/api/events"): handleEvents(c, clientID: clientID)
        default: c.respondError(404, "未找到")
        }
    }

    private func keyCookie(_ pin: String) -> String {
        "lb_key=\(pin); Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax"
    }

    // MARK: 网页

    private func servePage(_ c: HTTPConnection, headers: [(String, String)]) {
        var head = HTTPHead(200, [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-cache")])
        head.headers += headers
        c.respond(head, body: WebAssets.indexHTML())
    }

    private func handleAuth(_ req: HTTPRequest, _ c: HTTPConnection, clientID: String) {
        guard hub.pinLocked(ip: c.remoteIP) == false else {
            c.respondError(429, "尝试次数过多，请 1 分钟后再试")
            return
        }
        readJSON(req, c, limit: 4096) { [self] (body: [String: String]?) in
            let cfg = hub.config
            let ok = body?["pin"]?.trimmingCharacters(in: .whitespaces) == cfg.pin
            hub.recordPIN(success: ok, ip: c.remoteIP)
            if ok {
                hub.touch(id: clientID, ip: c.remoteIP, userAgent: req.userAgent, authorized: true)
                c.respondJSON(200, ["ok": "1"], headers: [("Set-Cookie", keyCookie(cfg.pin))])
            } else {
                c.respondError(403, "访问码不正确")
            }
        }
    }

    private func handleInfo(_ c: HTTPConnection, clientID: String, headers: [(String, String)]) {
        let cfg = hub.config
        let me = hub.client(clientID)
        struct Info: Codable {
            let hostName: String, hostKind: DeviceKind, allowUpload: Bool, protected: Bool
            let deviceID: String, deviceName: String, deviceKind: DeviceKind, devicePlatform: String, deviceBrowser: String
            let devices: [ServerHub.DeviceWire]
        }
        let info = Info(
            hostName: cfg.hostName, hostKind: cfg.hostKind, allowUpload: cfg.allowUpload, protected: cfg.requirePIN,
            deviceID: clientID, deviceName: me?.name ?? "此设备", deviceKind: me?.kind ?? .unknown,
            devicePlatform: me?.platform ?? "", deviceBrowser: me?.browser ?? "",
            devices: hub.devicesPayload()
        )
        c.respondJSON(200, info, headers: headers)
    }

    private func handleHello(_ req: HTTPRequest, _ c: HTTPConnection, clientID: String) {
        struct Hello: Codable { let name: String?; let kind: DeviceKind?; let platform: String? }
        readJSON(req, c, limit: 4096) { [self] (body: Hello?) in
            hub.hello(id: clientID, name: body?.name, kind: body?.kind, platform: body?.platform)
            let me = hub.client(clientID)
            c.respondJSON(200, ["id": clientID, "name": me?.name ?? ""])
        }
    }

    private func handleList(_ req: HTTPRequest, _ c: HTTPConnection, clientID: String) {
        let path = req.query["path"] ?? ""
        guard let listing = store.list(path) else {
            c.respondError(404, "文件夹不存在或已被移除")
            return
        }
        hub.update(clientID) { $0.activity = path.isEmpty ? "正在浏览共享文件夹" : "正在浏览 /\(listing.path)" }
        c.respondJSON(200, listing)
    }

    // MARK: 下载

    private func handleDownload(_ req: HTTPRequest, _ c: HTTPConnection, clientID: String) {
        guard let url = store.resolve(req.query["path"] ?? ""), url != store.root else {
            c.respondError(400, "路径无效")
            return
        }
        let target = url.resolvingSymlinksInPath()
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            c.respondError(404, "文件不存在或已被移除")
            return
        }
        let displayName = url.lastPathComponent
        let relPath = req.query["path"] ?? ""

        if values.isDirectory == true {
            streamArchive(of: target, name: displayName, path: relPath, method: req.method, c, clientID: clientID)
            return
        }

        let size = Int64(values.fileSize ?? 0)
        let mime = MIME.type(for: target)
        let inline = req.query["inline"] == "1" && MIME.isSafeInline(mime)

        var start: Int64 = 0
        var end: Int64 = max(0, size - 1)
        var status = 200
        if let range = req.headers["range"], range.hasPrefix("bytes="), size > 0 {
            let spec = range.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 2 {
                if parts[0].isEmpty, let suffix = Int64(parts[1]) {
                    start = max(0, size - suffix)
                } else if let s = Int64(parts[0]) {
                    start = s
                    if let e = Int64(parts[1]) { end = min(e, size - 1) }
                }
                guard start <= end, start < size else {
                    c.respond(HTTPHead(416, [("Content-Range", "bytes */\(size)")]), body: Data())
                    return
                }
                status = 206
            }
        }
        let length = size == 0 ? 0 : end - start + 1

        var head = HTTPHead(status, [
            ("Content-Type", mime),
            ("Content-Length", "\(length)"),
            ("Accept-Ranges", "bytes"),
            ("Content-Disposition", MIME.contentDisposition(inline ? "inline" : "attachment", filename: displayName)),
            ("Cache-Control", "no-cache"),
        ])
        if status == 206 { head.add("Content-Range", "bytes \(start)-\(end)/\(size)") }
        if let m = values.contentModificationDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            head.add("Last-Modified", f.string(from: m))
        }

        guard req.method == "GET", length > 0, let handle = try? FileHandle(forReadingFrom: target) else {
            c.send(head.serialized()) { _ in c.finish() }
            return
        }
        try? handle.seek(toOffset: UInt64(start))

        // 预览（图片、视频的分段请求）不算作一次下载，只更新动态。
        let transfer: Transfer? = inline
            ? nil
            : hub.startTransfer(.download, clientID: clientID, name: displayName, path: relPath, total: length, connection: c)
        if !inline, transfer == nil {
            try? handle.close()
            c.respondError(503, "Mac 正在准备退出，请稍后重试")
            return
        }
        if inline { hub.update(clientID) { $0.activity = "正在预览 \(displayName)" } }

        var remaining = length
        func pump() {
            if remaining <= 0 {
                try? handle.close()
                if let transfer { hub.endTransfer(transfer, .completed) }
                c.finish()
                return
            }
            let chunk = (try? handle.read(upToCount: Int(min(Int64(HTTPConnection.chunkSize), remaining)))) ?? Data()
            if chunk.isEmpty {
                try? handle.close()
                if let transfer { hub.endTransfer(transfer, .failed) }
                c.finish()
                return
            }
            remaining -= Int64(chunk.count)
            c.send(chunk) { ok in
                guard ok, transfer?.isCancelled != true else {
                    try? handle.close()
                    if let transfer { self.hub.endTransfer(transfer, transfer.isCancelled ? .cancelled : .failed) }
                    return
                }
                transfer?.add(chunk.count)
                pump()
            }
        }
        c.sendHead(head) { ok in ok ? pump() : { try? handle.close(); if let transfer { self.hub.endTransfer(transfer, .failed) } }() }
    }

    /// 文件夹和 App 等文件包：用 ditto 即时打包成 zip 流式发送，无需临时文件。
    private func streamArchive(of target: URL, name: String, path: String, method: String, _ c: HTTPConnection, clientID: String) {
        let zipName = name + ".zip"
        let head = HTTPHead(200, [
            ("Content-Type", "application/zip"),
            ("Content-Disposition", MIME.contentDisposition("attachment", filename: zipName)),
            ("Cache-Control", "no-cache"),
        ])
        guard method == "GET" else {
            c.send(head.serialized()) { _ in c.finish() }
            return
        }

        let estimate = ShareStore.totalSize(of: target)
        guard let transfer = hub.startTransfer(.download, clientID: clientID, name: zipName, path: path, total: estimate > 0 ? estimate : nil, connection: c) else {
            c.respondError(503, "Mac 正在准备退出，请稍后重试")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--zlibCompressionLevel", "0", target.path, "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            hub.endTransfer(transfer, .failed)
            c.respondError(500, "无法打包该文件夹")
            return
        }

        let reader = pipe.fileHandleForReading
        c.onClosed { if process.isRunning { process.terminate() } }

        func pump() {
            let chunk = reader.readData(ofLength: HTTPConnection.chunkSize)
            if chunk.isEmpty {
                process.waitUntilExit()
                hub.endTransfer(transfer, process.terminationStatus == 0 ? .completed : .failed)
                c.finish()
                return
            }
            c.send(chunk) { ok in
                guard ok, !transfer.isCancelled else {
                    if process.isRunning { process.terminate() }
                    self.hub.endTransfer(transfer, transfer.isCancelled ? .cancelled : .failed)
                    return
                }
                transfer.add(chunk.count)
                pump()
            }
        }
        c.sendHead(head) { ok in
            if ok { pump() } else { process.terminate(); self.hub.endTransfer(transfer, .failed) }
        }
    }

    // MARK: 缩略图

    private func handleThumb(_ req: HTTPRequest, _ c: HTTPConnection) {
        guard let url = store.resolve(req.query["path"] ?? "") else {
            c.respondError(400, "路径无效")
            return
        }
        let target = url.resolvingSymlinksInPath()
        let mtime = (try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(target.path)#\(mtime)" as NSString
        if let cached = thumbCache.object(forKey: key) {
            c.respond(HTTPHead(200, [("Content-Type", "image/jpeg"), ("Cache-Control", "max-age=3600")]), body: cached as Data)
            return
        }
        let request = QLThumbnailGenerator.Request(fileAt: target, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let self, let cg = rep?.cgImage, let data = APIHandler.jpeg(cg) else {
                c.respond(HTTPHead(404), body: Data())
                return
            }
            self.thumbCache.setObject(data as NSData, forKey: key)
            c.respond(HTTPHead(200, [("Content-Type", "image/jpeg"), ("Cache-Control", "max-age=3600")]), body: data)
        }
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        // 透明区域铺白底再压缩
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: flat).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    // MARK: 上传

    private func handleUpload(_ req: HTTPRequest, _ c: HTTPConnection, clientID: String) {
        guard hub.config.allowUpload else {
            c.respondError(403, "Mac 端已关闭上传")
            return
        }
        if req.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            c.respondError(411, "需要 Content-Length")
            return
        }
        guard let length = req.contentLength, length >= 0 else {
            c.respondError(411, "需要 Content-Length")
            return
        }
        let store = self.store
        guard let baseDir = store.writableDirectory(req.query["dir"] ?? "") else {
            c.respondError(403, "这个文件夹不能上传，请回到共享文件夹的根目录")
            return
        }
        guard let rawName = req.query["name"], var comps = ShareStore.components(of: rawName), !comps.isEmpty else {
            c.respondError(400, "文件名无效")
            return
        }
        comps = comps.map { String($0.prefix(255)) }

        if let free = (try? baseDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < length + 50_000_000 {
            c.respondError(507, "Mac 磁盘空间不足")
            return
        }

        // Register before creating folders or temporary files. Quit preparation and
        // transfer admission share one lock, so neither can slip past the other.
        let relPath = ((ShareStore.components(of: req.query["dir"] ?? "") ?? []) + comps).joined(separator: "/")
        let fileName = comps.last!
        guard let transfer = hub.startTransfer(.upload, clientID: clientID, name: fileName, path: relPath, total: length, connection: c) else {
            c.respondError(503, "Mac 正在准备退出，请稍后重试")
            return
        }
        var readingBody = false
        defer {
            if !readingBody { hub.endTransfer(transfer, .failed) }
        }

        // 带目录的上传（拖入文件夹）：逐级创建真实子文件夹
        var dir = baseDir
        for folder in comps.dropLast() {
            dir.appendPathComponent(folder)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) {
                guard isDir.boolValue, !dir.isSymlink else {
                    c.respondError(409, "同名文件已存在：\(folder)")
                    return
                }
            } else {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                    ShareStore.setOrigin(hub.client(clientID)?.name ?? "", for: dir)
                } catch {
                    c.respondError(500, "无法创建文件夹")
                    return
                }
            }
        }
        let part = dir.appendingPathComponent("\(ShareStore.partPrefix)\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil), let handle = try? FileHandle(forWritingTo: part) else {
            c.respondError(500, "无法写入文件")
            return
        }

        if req.headers["expect"]?.lowercased() == "100-continue" {
            c.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }

        var writeFailed = false
        readingBody = true
        c.readBody(length: length, onChunk: { chunk in
            do { try handle.write(contentsOf: chunk) } catch { writeFailed = true; return false }
            transfer.add(chunk.count)
            return !transfer.isCancelled
        }, completion: { [self] ok in
            try? handle.close()
            guard ok, !writeFailed else {
                try? FileManager.default.removeItem(at: part)
                hub.endTransfer(transfer, transfer.isCancelled ? .cancelled : .failed)
                if !c.isClosed { c.respondError(writeFailed ? 500 : 400, "上传未完成") }
                return
            }
            let dest = store.uniqueURL(in: dir, name: fileName)
            do {
                try FileManager.default.moveItem(at: part, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: part)
                hub.endTransfer(transfer, .failed)
                c.respondError(500, "无法保存文件")
                return
            }
            ShareStore.setOrigin(transfer.clientName, for: dest)
            if let ms = req.headers["x-lb-mtime"].flatMap(Double.init), ms > 0 {
                try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: ms / 1000)], ofItemAtPath: dest.path)
            }
            hub.endTransfer(transfer, .completed)
            // 上传的文件本来就会出现在共享列表里，所以可以告诉所有设备“谁传了什么”
            struct Uploaded: Codable { let device: String; let name: String }
            hub.send(event: "uploaded", data: Uploaded(device: clientID, name: dest.lastPathComponent).jsonData())
            // 根目录由 Mac 端的文件夹监听负责广播，子文件夹需要在这里通知
            if let d = req.query["dir"], !d.isEmpty { hub.broadcastFilesChanged(path: d) }
            c.respondJSON(201, ["name": dest.lastPathComponent])
        })
    }

    // MARK: 实时事件

    private func handleEvents(_ c: HTTPConnection, clientID: String) {
        let head = HTTPHead(200, [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Cache-Control", "no-cache"),
            ("X-Accel-Buffering", "no"),
        ])
        c.sendHead(head) { [self] ok in
            guard ok else { return }
            c.send(Data("retry: 2000\n\n".utf8))
            hub.openStream(clientID: clientID, connection: c)
            c.watchForDisconnect()
            hub.send(event: "devices", data: hub.devicesPayload().jsonData(), to: clientID)
        }
    }

    // MARK: 工具

    private func readJSON<T: Decodable>(_ req: HTTPRequest, _ c: HTTPConnection, limit: Int64, _ done: @escaping (T?) -> Void) {
        let length = req.contentLength ?? 0
        guard length <= limit else { c.respondError(413, "请求过大"); return }
        var body = Data()
        c.readBody(length: length, onChunk: { body.append($0); return true }) { _ in
            done(try? JSONDecoder().decode(T.self, from: body))
        }
    }
}
