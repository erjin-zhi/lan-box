import SwiftUI

/// 主窗口：左栏是共享状态、访问地址和设备星图，右侧是文件 / 设备 / 传输。
/// 菜单栏图标被其他图标挤掉时，可以从 Dock 打开这里。
struct MainWindowView: View {
    @ObservedObject var model: AppModel
    let showQR: () -> Void
    let quit: () -> Void

    @State private var tab: PopoverTab = .files
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 390, ideal: 400, max: 440)
        } detail: {
            detail
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 900, minHeight: 620)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadFileURLs(providers) { urls in
                model.add(urls)
                tab = .files
            }
            return true
        }
        .overlay(alignment: .bottom) { NoticeBanner(text: model.notice).padding(.bottom, 22) }
    }

    // MARK: 左栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LanBox").font(.title3.weight(.semibold))
                    HStack(spacing: 5) {
                        StatusDot(color: model.statusColor)
                        Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isRunning }, set: { $0 ? model.startSharing() : model.stopSharing() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(model.isRunning ? "停止共享" : "开始共享")
            }

            if let error = model.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.lastError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .card(radius: 12)
            }

            AddressCard(model: model, showQR: showQR)
                .fixedSize(horizontal: false, vertical: true)

            OrbitView(model: model)
                .padding(.vertical, 6)
                .card(radius: 18)

            Spacer(minLength: 0)

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
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: 右侧

    private var detail: some View {
        VStack(spacing: 14) {
            Picker("", selection: $tab) {
                Text(model.items.isEmpty ? "文件" : "文件 \(model.items.count)").tag(PopoverTab.files)
                Text(model.clients.isEmpty ? "设备" : "设备 \(model.onlineClients.count)").tag(PopoverTab.devices)
                Text(model.activeTransfers.isEmpty ? "传输" : "传输 \(model.activeTransfers.count)").tag(PopoverTab.transfers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            Group {
                switch tab {
                case .files: FilesTab(model: model, dropTargeted: dropTargeted)
                case .devices: DevicesTab(model: model, showsOrbit: false)
                case .transfers: TransfersTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { lock.withLock { urls.append(url) } }
            group.leave()
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
}
