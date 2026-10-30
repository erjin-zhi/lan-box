import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case files, devices, transfers
    var id: String { rawValue }
}

extension AppModel {
    var statusColor: Color {
        switch serverState {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var statusText: String {
        switch serverState {
        case .running:
            let n = onlineClients.count
            return n == 0 ? "正在共享，等待设备连接" : "正在共享，\(n) 台设备在线"
        case .starting: return "正在启动…"
        case .failed: return "启动失败"
        case .stopped: return "已停止共享"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let showQR: () -> Void
    let togglePin: () -> Bool
    let openWindow: () -> Void
    let quit: () -> Void

    @State private var tab: PopoverTab
    @State private var pinned = false
    @State private var dropTargeted = false

    init(model: AppModel, initialTab: PopoverTab = .files, showQR: @escaping () -> Void, togglePin: @escaping () -> Bool,
         openWindow: @escaping () -> Void = {}, quit: @escaping () -> Void) {
        self.model = model
        self.showQR = showQR
        self.togglePin = togglePin
        self.openWindow = openWindow
        self.quit = quit
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            if let error = model.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("关闭")
                }
                .padding(10)
                .card(radius: 12)
            }
            NotificationsOffHint(model: model)
            AddressCard(model: model, showQR: showQR)
            tabPicker
            Group {
                switch tab {
                case .files: FilesTab(model: model, dropTargeted: dropTargeted || model.isDropTargeted)
                case .devices: DevicesTab(model: model)
                case .transfers: TransfersTab(model: model)
                }
            }
            .frame(height: 330)
            footer
        }
        .padding(16)
        .frame(width: 404)
        .overlay(alignment: .bottom) { NoticeBanner(text: model.notice).padding(.bottom, 64) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { urls in
                model.add(urls)
                tab = .files
            }
            return true
        }
        .onChange(of: model.isDropTargeted) { _, targeted in if targeted { tab = .files } }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("LanBox").font(.headline)
                HStack(spacing: 5) {
                    StatusDot(color: model.statusColor)
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: openWindow) {
                Image(systemName: "macwindow")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("打开主窗口")

            Button {
                pinned = togglePin()
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(pinned ? "取消固定：点击其他地方时自动收起" : "固定面板：从 Finder 拖文件时保持打开")

            Toggle("", isOn: Binding(get: { model.isRunning }, set: { $0 ? model.startSharing() : model.stopSharing() }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.isRunning ? "停止共享" : "开始共享")
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            Text(model.items.isEmpty ? "文件" : "文件 \(model.items.count)").tag(PopoverTab.files)
            Text(model.onlineClients.isEmpty ? "设备" : "设备 \(model.onlineClients.count)").tag(PopoverTab.devices)
            Text(model.activeTransfers.isEmpty ? "传输" : "传输 \(model.activeTransfers.count)").tag(PopoverTab.transfers)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("在 Finder 中显示", systemImage: "folder", action: model.revealFolder)
                Divider()
                Button("选择共享文件夹…", systemImage: "folder.badge.gearshape", action: model.chooseFolder)
                Button("使用新的临时文件夹", systemImage: "folder.badge.plus", action: model.useNewTemporaryFolder)
            } label: {
                Label(model.folderDisplayName, systemImage: model.isTemporaryFolder ? "clock.arrow.circlepath" : "folder")
                    .lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .fixedSize()
            .help(model.rootURL.path)

            Spacer()

            SettingsMenu(model: model, quit: quit)
        }
        .controlSize(.regular)
    }
}

// MARK: - 设置菜单

struct SettingsMenu: View {
    @ObservedObject var model: AppModel
    let quit: () -> Void

    var body: some View {
        Menu {
            Section("访问") {
                Toggle("允许设备上传", isOn: $model.allowUpload)
                Toggle("需要访问码", isOn: $model.requirePIN)
                Button("更换访问码", action: model.regeneratePIN)
                    .disabled(!model.requirePIN)
            }
            Section("拖入文件时") {
                Picker("拖入方式", selection: $model.addMode) {
                    ForEach(ShareStore.AddMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("通知") {
                Toggle("新设备连接", isOn: $model.notifyNewDevices)
                Toggle("收到文件", isOn: $model.notifyUploads)
            }
            Divider()
            Toggle("在 Dock 中显示", isOn: $model.showInDock)
            Toggle("登录时启动", isOn: $model.launchAtLogin)
            Divider()
            Button("退出 LanBox", action: quit).keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .help("设置")
    }
}
