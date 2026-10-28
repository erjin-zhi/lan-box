import AppKit
import Network
import ServiceManagement
import SwiftUI
import UserNotifications

/// 共享文件夹顶层的一项，用于 Mac 端列表。
struct SharedItem: Identifiable, Equatable {
    enum Kind { case file, folder, package }
    var id: String { name }
    let name: String
    let url: URL
    let kind: Kind
    let isLink: Bool
    let target: URL?
    let isBroken: Bool
    let size: Int64?
    let from: String?
    let modified: Date?
}

/// 星图动效里的一次“文件气泡”：设备上传完成或下载完成。
struct OrbitEvent: Identifiable {
    let id = UUID()
    let clientID: String
    let fileName: String
    let direction: Transfer.Direction
    let date = Date()
}

@MainActor
final class AppModel: ObservableObject {
    let hub = ServerHub()
    private let handler: APIHandler
    private var server: HTTPServer!
    private let defaults = UserDefaults.standard

    @Published private(set) var serverState: HTTPServer.State = .stopped
    @Published private(set) var interfaces: [NetInterface] = []
    @Published var selectedInterfaceID: String? {
        didSet { defaults.set(selectedInterfaceID, forKey: "interface") }
    }
    @Published private(set) var rootURL: URL
    @Published private(set) var isTemporaryFolder: Bool
    @Published private(set) var items: [SharedItem] = []
    @Published private(set) var clients: [ClientInfo] = []
    @Published private(set) var transfers: [Transfer] = []
    @Published var lastError: String?

    @Published var allowUpload: Bool { didSet { defaults.set(allowUpload, forKey: "allowUpload"); pushConfig(); hub.broadcastHost() } }
    @Published var requirePIN: Bool { didSet { defaults.set(requirePIN, forKey: "requirePIN"); pushConfig() } }
    @Published private(set) var pin: String { didSet { defaults.set(pin, forKey: "pin"); pushConfig() } }
    @Published var addMode: ShareStore.AddMode { didSet { defaults.set(addMode.rawValue, forKey: "addMode") } }
    @Published var notifyNewDevices: Bool { didSet { defaults.set(notifyNewDevices, forKey: "notifyNewDevices") } }
    @Published var notifyUploads: Bool { didSet { defaults.set(notifyUploads, forKey: "notifyUploads") } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "无法更改登录时启动：\(error.localizedDescription)"
            }
        }
    }

    let hostName = NetworkInfo.computerName
    let bonjourName = NetworkInfo.bonjourHostName
    let isLaptop = NetworkInfo.isLaptop

    private var watcher: DispatchSourceFileSystemObject?
    private var pathMonitor: NWPathMonitor?
    private var refreshPending = false
    private var clockTimer: Timer?
    private var pendingUploads: [Transfer] = []
    private var uploadNoticeTask: Task<Void, Never>?
    private var fileChangeTask: Task<Void, Never>?

    /// 动效：最近结束的传输（几秒后自动移除）。
    @Published private(set) var orbitEvents: [OrbitEvent] = []
    /// 动效：设备上线 / 离线的时间，用于入场和退场动画。
    private(set) var joinTimes: [String: Date] = [:]
    private(set) var leavers: [String: (client: ClientInfo, date: Date)] = [:]

    /// 下拉提示：拖入菜单栏图标时为 true。
    @Published var isDropTargeted = false

    init() {
        defaults.register(defaults: [
            "allowUpload": true, "requirePIN": true, "addMode": "link",
            "notifyNewDevices": true, "notifyUploads": true, "port": 8765,
        ])
        allowUpload = defaults.bool(forKey: "allowUpload")
        requirePIN = defaults.bool(forKey: "requirePIN")
        pin = defaults.string(forKey: "pin") ?? AppModel.makePIN()
        addMode = ShareStore.AddMode(rawValue: defaults.string(forKey: "addMode") ?? "") ?? .link
        notifyNewDevices = defaults.bool(forKey: "notifyNewDevices")
        notifyUploads = defaults.bool(forKey: "notifyUploads")
        selectedInterfaceID = defaults.string(forKey: "interface")

        AppModel.cleanUpOldTemporaryFolders()
        let root: URL
        if let saved = defaults.string(forKey: "customFolder"),
           (try? URL(fileURLWithPath: saved).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = URL(fileURLWithPath: saved)
            isTemporaryFolder = false
        } else {
            root = AppModel.makeTemporaryFolder()
            isTemporaryFolder = true
        }
        rootURL = root
        handler = APIHandler(hub: hub, store: ShareStore(root: root))
        defaults.set(pin, forKey: "pin")

        server = HTTPServer { [handler] req, conn in handler.handle(req, conn) }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverStateChanged(state) }
        }
        hub.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        hub.onNewClient = { [weak self] client in
            Task { @MainActor in self?.notifyNewClient(client) }
        }
        hub.onUploadFinished = { [weak self] t in
            Task { @MainActor in self?.uploadFinished(t) }
        }
        hub.onTransferEnded = { [weak self] t in
            guard t.state == .completed else { return }
            Task { @MainActor in self?.addOrbitEvent(t) }
        }

        pushConfig()
        refreshInterfaces()
        startWatching()
        reloadItems()
        startNetworkMonitor()
        startSharing()

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromHub() }
        }
    }

    // MARK: 服务器

    var isRunning: Bool { if case .running = serverState { return true } else { return false } }

    var port: UInt16? { if case let .running(p) = serverState { return p } else { return nil } }

    var selectedInterface: NetInterface? {
        interfaces.first { $0.id == selectedInterfaceID } ?? interfaces.first
    }

    /// 不含访问码的地址，用于显示。
    var displayAddress: String? {
        guard let port, let iface = selectedInterface else { return nil }
        return "http://\(iface.address):\(port)"
    }

    /// 扫码 / 复制用的完整链接，含访问码则免输入。
    var shareLink: String? {
        guard let base = displayAddress else { return nil }
        return requirePIN ? "\(base)/?k=\(pin)" : base
    }

    var bonjourAddress: String? {
        guard let port, let bonjourName else { return nil }
        return "http://\(bonjourName):\(port)"
    }

    func startSharing() {
        lastError = nil
        let port = UInt16(clamping: defaults.integer(forKey: "port"))
        server.start(preferredPort: port == 0 ? 8765 : port)
    }

    func stopSharing() {
        hub.broadcastShutdown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [server] in server?.stop() }
    }

    func toggleSharing() { isRunning ? stopSharing() : startSharing() }

    private func serverStateChanged(_ state: HTTPServer.State) {
        serverState = state
        switch state {
        case .running(let p): defaults.set(Int(p), forKey: "port")
        case .failed(let reason): lastError = "无法启动共享服务：\(reason)"
        default: break
        }
    }

    private func pushConfig() {
        hub.config = ServerConfig(requirePIN: requirePIN, pin: pin, allowUpload: allowUpload,
                                  hostName: hostName, hostKind: isLaptop ? .laptop : .desktop,
                                  localAddresses: Set(interfaces.map(\.address)).union(["127.0.0.1", "::1"]))
    }

    func regeneratePIN() {
        pin = AppModel.makePIN()
        hub.revokeAll()
    }

    private static func makePIN() -> String { String(format: "%06d", Int.random(in: 0..<1_000_000)) }

    // MARK: 网络地址

    private func refreshInterfaces() {
        interfaces = NetworkInfo.interfaces()
        pushConfig()
        if let id = selectedInterfaceID, !interfaces.contains(where: { $0.id == id }) {
            // 网络切换后保留同一网卡（地址可能变了）
            let bsd = id.split(separator: "-").first.map(String.init)
            selectedInterfaceID = interfaces.first { $0.bsdName == bsd }?.id ?? interfaces.first?.id
        } else if selectedInterfaceID == nil {
            selectedInterfaceID = interfaces.first?.id
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self?.refreshInterfaces()
            }
        }
        monitor.start(queue: DispatchQueue(label: "lanbox.path"))
        pathMonitor = monitor
    }

    // MARK: 共享文件夹

    var folderDisplayName: String { isTemporaryFolder ? "临时文件夹" : rootURL.lastPathComponent }

    private static var temporaryBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LanBox", isDirectory: true)
    }

    private static func makeTemporaryFolder() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = temporaryBase.appendingPathComponent("共享 \(f.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 只删除没有“真实文件”的旧临时文件夹（里面只有替身），收到的文件不会被删。
    private static func cleanUpOldTemporaryFolders() {
        let fm = FileManager.default
        guard let sessions = try? fm.contentsOfDirectory(at: temporaryBase, includingPropertiesForKeys: nil) else { return }
        for dir in sessions {
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let onlyLinks = children.allSatisfy { $0.isSymlink || $0.lastPathComponent == ".DS_Store" }
            if onlyLinks { try? fm.removeItem(at: dir) }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "共享此文件夹"
        panel.message = "选择要在局域网中共享的文件夹。设备上传的文件也会保存在这里。"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url, temporary: false)
    }

    func useNewTemporaryFolder() {
        setRoot(AppModel.makeTemporaryFolder(), temporary: true)
    }

    private func setRoot(_ url: URL, temporary: Bool) {
        rootURL = url
        isTemporaryFolder = temporary
        defaults.set(temporary ? nil : url.path, forKey: "customFolder")
        handler.store = ShareStore(root: url)
        startWatching()
        reloadItems()
        hub.send(event: "reset", data: Data("{}".utf8))
    }

    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([rootURL])
    }

    private func startWatching() {
        watcher?.cancel()
        let fd = open(rootURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // 上传过程中目录会频繁变化，合并为一次刷新
            self?.fileChangeTask?.cancel()
            self?.fileChangeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.reloadItems()
                self?.hub.broadcastFilesChanged()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func reloadItems() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? []
        var result: [SharedItem] = []
        for name in names where !name.hasPrefix(".") {
            let url = rootURL.appendingPathComponent(name)
            let isLink = url.isSymlink
            let target = isLink ? url.resolvingSymlinksInPath() : nil
            // fileExists 会跟随替身；原文件被移走时返回 false
            let broken = isLink && !FileManager.default.fileExists(atPath: url.path)
            let values = broken ? nil : try? (target ?? url).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
            let kind: SharedItem.Kind = values?.isPackage == true ? .package : (values?.isDirectory == true ? .folder : .file)
            result.append(SharedItem(
                name: name, url: url, kind: kind, isLink: isLink, target: target,
                isBroken: broken || values == nil,
                size: kind == .file ? values?.fileSize.map(Int64.init) : nil,
                from: ShareStore.origin(of: url),
                modified: values?.contentModificationDate
            ))
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if result != items { items = result }
    }

    /// Finder 拖入：默认创建替身，不复制文件。
    func add(_ urls: [URL]) {
        let store = handler.store
        let mode = addMode
        if mode == .copy {
            Task.detached { store.add(urls, mode: .copy) }
        } else {
            store.add(urls, mode: .link)
            reloadItems()
        }
    }

    func pickFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "加入共享"
        NSApp.activate()
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// 替身只删除链接本身；真实文件移到废纸篓。
    func remove(_ item: SharedItem) {
        if item.isLink {
            try? FileManager.default.removeItem(at: item.url)
        } else {
            NSWorkspace.shared.recycle([item.url])
        }
        reloadItems()
    }

    func reveal(_ item: SharedItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.target ?? item.url])
    }

    var receivedItemsInTemporaryFolder: [SharedItem] {
        isTemporaryFolder ? items.filter { !$0.isLink } : []
    }

    /// 退出前把临时文件夹里收到的文件移到“下载”。
    func moveReceivedToDownloads() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let store = ShareStore(root: downloads)
        for item in receivedItemsInTemporaryFolder {
            let dest = store.uniqueURL(in: downloads, name: item.name)
            try? FileManager.default.moveItem(at: item.url, to: dest)
        }
    }

    // MARK: 设备与传输

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshPending = false
            self?.refreshFromHub()
        }
    }

    private func refreshFromHub() {
        let previous = Dictionary(uniqueKeysWithValues: onlineClients.map { ($0.id, $0) })
        // 在线设备按首次出现排序（心跳不会让列表跳动），离线设备按离开时间排序
        clients = hub.allClients.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.isOnline ? $0.firstSeen < $1.firstSeen : $0.lastSeen > $1.lastSeen
        }
        transfers = hub.allTransfers.reversed()

        let now = Date()
        let current = Set(onlineClients.map(\.id))
        for id in current where previous[id] == nil {
            joinTimes[id] = now
            leavers[id] = nil
        }
        for (id, client) in previous where !current.contains(id) {
            leavers[id] = (client, now)
        }
        leavers = leavers.filter { now.timeIntervalSince($0.value.date) < 1 }
        orbitEvents.removeAll { now.timeIntervalSince($0.date) > 4 }
        objectWillChange.send()
    }

    private func addOrbitEvent(_ t: Transfer) {
        orbitEvents.append(OrbitEvent(clientID: t.clientID, fileName: t.name, direction: t.direction))
        if orbitEvents.count > 12 { orbitEvents.removeFirst(orbitEvents.count - 12) }
    }

    /// 在线且已通过验证的设备，按首次出现排序（星图上的位置保持稳定）。
    var onlineClients: [ClientInfo] {
        clients.filter(\.isPresent).sorted { $0.firstSeen < $1.firstSeen }
    }
    var recentClients: [ClientInfo] { clients.filter { !$0.isPresent } }
    var activeTransfers: [Transfer] { transfers.filter { $0.state == .active } }

    func setBlocked(_ client: ClientInfo, _ blocked: Bool) { hub.setBlocked(client.id, blocked) }
    func forget(_ client: ClientInfo) { hub.forget(client.id) }
    func clearFinishedTransfers() { hub.clearFinishedTransfers() }

    func copyLink() {
        guard let link = shareLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func openInBrowser() {
        if let link = shareLink, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    // MARK: 通知

    /// `swift run` 启动的裸可执行文件没有 Bundle ID，调用通知中心会直接崩溃。
    static let canNotify = Bundle.main.bundleIdentifier != nil

    func requestNotificationPermission() {
        guard AppModel.canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyNewClient(_ client: ClientInfo) {
        refreshFromHub()
        guard notifyNewDevices else { return }
        post(title: "\(client.name) 已连接", body: "\(client.platform) · \(client.browser) · \(client.ip)")
    }

    private func uploadFinished(_ t: Transfer) {
        reloadItems()
        guard notifyUploads else { return }
        pendingUploads.append(t)
        uploadNoticeTask?.cancel()
        uploadNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let batch = self.pendingUploads
            self.pendingUploads = []
            guard let first = batch.first else { return }
            let total = batch.reduce(Int64(0)) { $0 + $1.done }
            let senders = Set(batch.map(\.clientName)).sorted().joined(separator: "、")
            let title = batch.count == 1 ? "收到 \(first.name)" : "收到 \(batch.count) 个文件"
            self.post(title: title, body: "来自 \(senders)，共 \(Fmt.bytes(total))")
        }
    }

    private func post(title: String, body: String) {
        guard AppModel.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
