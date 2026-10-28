import Foundation

/// 一个访问过共享网页的设备。所有可变状态都由 ServerHub 的锁保护。
struct ClientInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var customName: Bool
    var kind: DeviceKind
    var platform: String
    var browser: String
    var ip: String
    var firstSeen: Date
    var lastSeen: Date
    /// 最近一次心跳。网页每 5 秒回应一次服务器的 ping。
    var lastBeat: Date
    /// 网页是否在前台。
    var visible: Bool
    /// 网页已关闭（收到 bye 或实时连接全部断开）。
    var left: Bool
    var liveStreams: Int
    var activeTransfers: Int
    var authorized: Bool
    var blocked: Bool
    var activity: String
    var downloads: Int
    var uploads: Int

    static let heartbeatTimeout: TimeInterval = 15

    /// 手机锁屏、切走、断网时 TCP 往往不会正常关闭，所以以心跳为准，而不是连接是否存在。
    var isOnline: Bool {
        if blocked { return false }
        if activeTransfers > 0 { return true }
        return !left && Date().timeIntervalSince(lastBeat) < ClientInfo.heartbeatTimeout
    }
    var isPresent: Bool { isOnline && authorized }
    var symbol: String { kind.symbol(platform: platform) }
}

final class Transfer: Identifiable, @unchecked Sendable {
    enum Direction: String, Codable { case upload, download }
    enum State: String, Codable { case active, completed, failed, cancelled }

    let id = UUID()
    let direction: Direction
    let clientID: String
    let clientName: String
    let name: String
    let path: String
    let total: Int64?
    let started = Date()

    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _state: State = .active
    private var _ended: Date?
    private var _speed: Double = 0
    private var lastSample: (Date, Int64)?
    var onCancel: (() -> Void)?

    init(direction: Direction, clientID: String, clientName: String, name: String, path: String, total: Int64?) {
        self.direction = direction
        self.clientID = clientID
        self.clientName = clientName
        self.name = name
        self.path = path
        self.total = total
    }

    var done: Int64 { lock.withLock { _done } }
    var state: State { lock.withLock { _state } }
    var ended: Date? { lock.withLock { _ended } }
    var speed: Double { lock.withLock { _speed } }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    func add(_ bytes: Int) { lock.withLock { _done += Int64(bytes) } }

    func finish(_ state: State) {
        lock.withLock {
            guard _state == .active else { return }
            _state = state
            _ended = Date()
            let elapsed = max(0.001, _ended!.timeIntervalSince(started))
            _speed = Double(_done) / elapsed
        }
    }

    private var _cancelled = false
    var isCancelled: Bool { lock.withLock { _cancelled } }

    /// 只打标记并断开连接；状态由传输循环通过 hub.endTransfer 收尾。
    func cancel() {
        lock.withLock { _cancelled = true }
        onCancel?()
    }

    /// 由 hub 定时调用，平滑计算当前速度。
    func sample() {
        lock.withLock {
            guard _state == .active else { return }
            let now = Date()
            if let (t, d) = lastSample {
                let dt = now.timeIntervalSince(t)
                if dt > 0 {
                    let instant = Double(_done - d) / dt
                    _speed = _speed == 0 ? instant : _speed * 0.6 + instant * 0.4
                }
            }
            lastSample = (now, _done)
        }
    }

    struct Wire: Codable {
        let id: String, direction: Direction, name: String, total: Int64?, done: Int64, state: State, speed: Double
    }

    var wire: Wire {
        Wire(id: id.uuidString, direction: direction, name: name, total: total, done: done, state: state, speed: speed)
    }
}

/// 设置的线程安全快照，供服务器线程读取。
struct ServerConfig {
    var requirePIN = true
    var pin = "000000"
    var allowUpload = true
    var hostName = "Mac"
    var hostKind: DeviceKind = .laptop
    /// 本机地址，用来识别“在这台 Mac 上打开的浏览器”。
    var localAddresses: Set<String> = ["127.0.0.1", "::1"]
}

/// 服务器端的共享状态中心：设备、传输、实时事件订阅。
final class ServerHub: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: ClientInfo] = [:]
    private var transfers: [Transfer] = []
    private var streams: [UUID: (clientID: String, conn: HTTPConnection)] = [:]
    private var failedPINAttempts: [String: (count: Int, until: Date?)] = [:]
    private var _config = ServerConfig()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "lanbox.hub")
    private var tickCount = 0
    private var lastOnline: Set<String> = []

    /// 状态变化回调（任意线程），AppModel 负责合并到主线程。
    var onChange: (() -> Void)?
    /// 首次出现的新设备。
    var onNewClient: ((ClientInfo) -> Void)?
    /// 上传完成。
    var onUploadFinished: ((Transfer) -> Void)?
    /// 任意传输结束（用于 Mac 端动效）。
    var onTransferEnded: ((Transfer) -> Void)?

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    var config: ServerConfig {
        get { lock.withLock { _config } }
        set { lock.withLock { _config = newValue } }
    }

    // MARK: 设备

    /// 记录一次请求，返回该设备当前信息。
    @discardableResult
    func touch(id: String, ip: String, userAgent: String, authorized: Bool) -> ClientInfo {
        var isNew = false
        let info: ClientInfo = lock.withLock {
            if var c = clients[id] {
                c.lastSeen = Date()
                c.lastBeat = Date()
                c.left = false
                c.ip = ip
                if authorized && !c.authorized { c.authorized = true; isNew = true }
                clients[id] = c
                return c
            }
            let profile = DeviceProfile(userAgent: userAgent)
            let isLocal = _config.localAddresses.contains(ip)
            let c = ClientInfo(
                id: id, name: uniqueName(isLocal ? "这台 Mac 的浏览器" : profile.defaultName, ip: ip), customName: false,
                kind: profile.kind, platform: profile.platform, browser: profile.browser, ip: ip,
                firstSeen: Date(), lastSeen: Date(), lastBeat: Date(), visible: true, left: false,
                liveStreams: 0, activeTransfers: 0, authorized: authorized, blocked: false,
                activity: authorized ? "打开了共享页面" : "等待输入访问码", downloads: 0, uploads: 0
            )
            clients[id] = c
            isNew = authorized
            return c
        }
        if isNew {
            onNewClient?(info)
            broadcastDevices()
        }
        onChange?()
        return info
    }

    /// 同名设备依次命名为 “iPhone”“iPhone 2”…
    private func uniqueName(_ base: String, ip: String) -> String {
        // 只和在线设备比较，离开过的同名设备不占用名字
        let names = Set(clients.values.filter(\.isOnline).map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func client(_ id: String) -> ClientInfo? { lock.withLock { clients[id] } }

    /// 网页心跳。即使还没输入访问码也会发送，这样 Mac 端能看到“正在输入访问码”的设备何时离开。
    func heartbeat(id: String, ip: String, userAgent: String, authorized: Bool, visible: Bool) {
        touch(id: id, ip: ip, userAgent: userAgent, authorized: authorized)
        var changed = false
        lock.withLock {
            if clients[id]?.visible != visible { changed = true }
            clients[id]?.visible = visible
        }
        if changed { broadcastDevices() }
        checkPresence()
    }

    /// 网页关闭时通过 sendBeacon 发来。
    func bye(id: String) {
        lock.withLock {
            clients[id]?.left = true
            clients[id]?.visible = false
            clients[id]?.lastSeen = Date()
        }
        checkPresence()
    }

    func update(_ id: String, _ change: (inout ClientInfo) -> Void) {
        lock.withLock {
            if var c = clients[id] { change(&c); clients[id] = c }
        }
        onChange?()
    }

    func hello(id: String, name: String?, kind: DeviceKind?, platform: String?) {
        update(id) { c in
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                c.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                c.customName = true
            }
            if let kind, kind != .unknown {
                // iPadOS Safari 会伪装成 Mac，由网页根据触控能力纠正。
                if kind == .tablet && c.platform == "macOS" {
                    c.platform = "iPadOS"
                    if !c.customName { c.name = "iPad" }
                }
                c.kind = kind
            }
            if let platform, !platform.isEmpty, c.platform == "未知系统" { c.platform = platform }
        }
        broadcastDevices()
    }

    func isBlocked(_ id: String, ip: String) -> Bool {
        lock.withLock { clients[id]?.blocked == true }
    }

    func setBlocked(_ id: String, _ blocked: Bool) {
        update(id) { $0.blocked = blocked }
        if blocked {
            let conns = lock.withLock { streams.values.filter { $0.clientID == id }.map(\.conn) }
            conns.forEach { $0.cancel() }
            let active = lock.withLock { transfers.filter { $0.clientID == id && $0.state == .active } }
            active.forEach { $0.cancel() }
        }
    }

    /// 没通过验证就离开的设备 1 分钟后移除；已离线的设备保留 1 小时作为“最近访问”。
    private func pruneStaleClients() {
        let now = Date()
        lock.withLock {
            clients = clients.filter { _, c in
                if c.isOnline || c.blocked { return true }
                let idle = now.timeIntervalSince(c.lastSeen)
                return c.authorized ? idle < 3600 : idle < 60
            }
        }
    }

    func forget(_ id: String) {
        lock.withLock { _ = clients.removeValue(forKey: id) }
        onChange?()
    }

    /// 清除所有设备的访问状态（例如更换了访问码）。
    func revokeAll() {
        let conns = lock.withLock { () -> [HTTPConnection] in
            for key in clients.keys { clients[key]?.authorized = false }
            return streams.values.map(\.conn)
        }
        conns.forEach { $0.cancel() }
        onChange?()
    }

    var allClients: [ClientInfo] { lock.withLock { Array(clients.values) } }

    // MARK: 访问码限流

    func pinLocked(ip: String) -> Bool {
        lock.withLock {
            guard let until = failedPINAttempts[ip]?.until else { return false }
            return until > Date()
        }
    }

    func recordPIN(success: Bool, ip: String) {
        lock.withLock {
            if success { failedPINAttempts[ip] = nil; return }
            var entry = failedPINAttempts[ip] ?? (0, nil)
            entry.count += 1
            if entry.count >= 5 { entry.until = Date().addingTimeInterval(60); entry.count = 0 }
            failedPINAttempts[ip] = entry
        }
    }

    // MARK: 传输

    func startTransfer(_ direction: Transfer.Direction, clientID: String, name: String, path: String, total: Int64?, connection: HTTPConnection) -> Transfer {
        let clientName = client(clientID)?.name ?? "未知设备"
        let t = Transfer(direction: direction, clientID: clientID, clientName: clientName, name: name, path: path, total: total)
        t.onCancel = { [weak connection] in connection?.cancel() }
        lock.withLock {
            transfers.append(t)
            // 只保留最近 200 条记录
            if transfers.count > 200 {
                let removable = transfers.firstIndex { $0.state != .active }
                if let removable { transfers.remove(at: removable) }
            }
        }
        update(clientID) { c in
            c.activity = direction == .upload ? "正在上传 \(name)" : "正在下载 \(name)"
            c.activeTransfers += 1
            if direction == .upload { c.uploads += 1 } else { c.downloads += 1 }
        }
        pushTransfer(t)
        broadcastDevices()
        return t
    }

    func endTransfer(_ t: Transfer, _ state: Transfer.State) {
        let wasActive = t.state == .active
        t.finish(state)
        let verb: String
        switch (t.direction, t.state) {
        case (.upload, .completed): verb = "上传了 \(t.name)"
        case (.download, .completed): verb = "下载了 \(t.name)"
        case (.upload, _): verb = "上传中断：\(t.name)"
        case (.download, _): verb = "下载中断：\(t.name)"
        }
        update(t.clientID) {
            $0.activity = verb
            $0.lastSeen = Date()
            if wasActive { $0.activeTransfers = max(0, $0.activeTransfers - 1) }
        }
        pushTransfer(t)
        if wasActive { onTransferEnded?(t); broadcastDevices() }
        if t.direction == .upload && t.state == .completed { onUploadFinished?(t) }
    }

    var allTransfers: [Transfer] { lock.withLock { transfers } }

    func clearFinishedTransfers() {
        lock.withLock { transfers.removeAll { $0.state != .active } }
        onChange?()
    }

    var hasActiveTransfers: Bool { lock.withLock { transfers.contains { $0.state == .active } } }

    // MARK: 实时事件（SSE）

    func openStream(clientID: String, connection: HTTPConnection) {
        lock.withLock {
            streams[connection.id] = (clientID, connection)
            clients[clientID]?.liveStreams += 1
        }
        connection.onClosed { [weak self] in self?.closeStream(connection) }
        onChange?()
        broadcastDevices()
    }

    private func closeStream(_ connection: HTTPConnection) {
        lock.withLock {
            if let s = streams.removeValue(forKey: connection.id), var c = clients[s.clientID] {
                c.liveStreams -= 1
                c.lastSeen = Date()
                // 正常关闭标签页会走到这里；刷新页面时新的请求会立刻把 left 清掉
                if c.liveStreams <= 0 { c.left = true }
                clients[s.clientID] = c
            }
        }
        // 留一点时间给“刷新页面”的重连，再判断是否真的离开
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkPresence() }
        onChange?()
    }

    /// 在线集合有变化时通知 Mac 端和所有网页。
    func checkPresence() {
        let online = lock.withLock { Set(clients.values.filter(\.isPresent).map(\.id)) }
        let changed = lock.withLock { () -> Bool in
            defer { lastOnline = online }
            return online != lastOnline
        }
        if changed { broadcastDevices() }
        onChange?()
    }

    func send(event: String, data: Data, to clientID: String? = nil) {
        var payload = Data("event: \(event)\ndata: ".utf8)
        payload.append(data)
        payload.append(Data("\n\n".utf8))
        let targets = lock.withLock { streams.values.filter { clientID == nil || $0.clientID == clientID }.map(\.conn) }
        targets.forEach { $0.send(payload) }
    }

    /// 网页星图用：`up` / `down` 表示该设备正在上传 / 下载（只给方向，不透露别人在下载什么）。
    struct DeviceWire: Codable {
        let id: String, name: String, kind: DeviceKind, platform: String, online: Bool, host: Bool
        var up = false, down = false
    }

    func devicesPayload() -> [DeviceWire] {
        let cfg = config
        var list = [DeviceWire(id: "host", name: cfg.hostName, kind: cfg.hostKind, platform: "macOS", online: true, host: true)]
        let (online, active) = lock.withLock {
            (clients.values.filter(\.isPresent), transfers.filter { $0.state == .active })
        }
        let uploading = Set(active.filter { $0.direction == .upload }.map(\.clientID))
        let downloading = Set(active.filter { $0.direction == .download }.map(\.clientID))
        list += online.sorted { $0.firstSeen < $1.firstSeen }.map {
            DeviceWire(id: $0.id, name: $0.name, kind: $0.kind, platform: $0.platform, online: $0.visible, host: false,
                       up: uploading.contains($0.id), down: downloading.contains($0.id))
        }
        if !uploading.isEmpty || !downloading.isEmpty { list[0].up = !downloading.isEmpty; list[0].down = !uploading.isEmpty }
        return list
    }

    func broadcastDevices() {
        send(event: "devices", data: devicesPayload().jsonData())
    }

    func broadcastFilesChanged(path: String = "") {
        send(event: "files", data: ["path": path].jsonData())
    }

    func broadcastHost() {
        let cfg = config
        struct Host: Codable { let name: String; let sharing: Bool; let allowUpload: Bool }
        send(event: "host", data: Host(name: cfg.hostName, sharing: true, allowUpload: cfg.allowUpload).jsonData())
    }

    func broadcastShutdown() {
        send(event: "shutdown", data: Data("{}".utf8))
    }

    private func pushTransfer(_ t: Transfer) {
        // 下载进度由服务器推送给发起设备；上传进度网页自己知道。
        guard t.direction == .download else { return }
        send(event: "transfer", data: t.wire.jsonData(), to: t.clientID)
    }

    private func tick() {
        let active = lock.withLock { transfers.filter { $0.state == .active } }
        active.forEach {
            $0.sample()
            pushTransfer($0)
        }
        tickCount += 1
        if tickCount % 10 == 0 {
            // 每 5 秒 ping 一次，网页收到后回心跳；同时充当连接保活
            send(event: "ping", data: Data("{}".utf8))
            pruneStaleClients()
            checkPresence()
        } else if !active.isEmpty {
            onChange?()
        }
    }
}
