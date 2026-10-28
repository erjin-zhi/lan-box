import SwiftUI

struct AddressCard: View {
    @ObservedObject var model: AppModel
    let showQR: () -> Void
    @State private var copied = false

    var body: some View {
        Group {
            switch model.serverState {
            case .running:
                if model.interfaces.isEmpty { noNetwork } else { running }
            case .starting:
                HStack { ProgressView().controlSize(.small); Text("正在启动共享服务…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 112)
            case .failed(let reason):
                stopped(title: "共享服务未能启动", message: reason)
            case .stopped:
                stopped(title: "共享已停止", message: "其他设备暂时无法访问。文件仍保留在共享文件夹中。")
            }
        }
        .padding(14)
        .card(radius: 18)
    }

    private var running: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                Text("同一网络中的设备可以打开")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(model.displayAddress ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                interfaceMenu

                if model.requirePIN {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.system(size: 10))
                        Text("访问码").font(.caption)
                        Text(spacedPIN)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Button {
                        model.copyLink()
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
                    } label: {
                        Label(copied ? "已拷贝" : "拷贝链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(model.requirePIN ? "链接中已包含访问码，对方打开即可直接进入" : "拷贝访问链接")

                    Button("打开", systemImage: "safari", action: model.openInBrowser)
                        .help("在本机浏览器中预览访客看到的页面")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Button(action: showQR) {
                QRImage(text: model.shareLink ?? "", size: 112)
            }
            .buttonStyle(.plain)
            .help("放大二维码")
        }
    }

    private var interfaceMenu: some View {
        Menu {
            ForEach(model.interfaces) { iface in
                Button {
                    model.selectedInterfaceID = iface.id
                } label: {
                    Text("\(iface.displayName)  \(iface.address)")
                    if iface.id == model.selectedInterface?.id { Image(systemName: "checkmark") }
                }
            }
            if let bonjour = model.bonjourAddress {
                Divider()
                Button("拷贝 \(bonjour)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bonjour, forType: .string)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.selectedInterface?.displayName.contains("Wi") == true ? "wifi" : "network")
                Text(model.selectedInterface?.displayName ?? "")
                if model.interfaces.count > 1 { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var spacedPIN: String {
        let p = model.pin
        guard p.count == 6 else { return p }
        return "\(p.prefix(3)) \(p.suffix(3))"
    }

    private var noNetwork: some View {
        stopped(title: "未连接到局域网", message: "连接 Wi‑Fi 或有线网络后，地址会自动出现在这里。")
    }

    private func stopped(title: String, message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.isRunning ? "wifi.slash" : "pause.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.isRunning {
                Button("开始共享", action: model.startSharing)
                    .buttonStyle(.glassProminent)
            }
        }
        .frame(minHeight: 112)
    }
}

struct QRImage: View {
    let text: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(.white)
            if let image = QRCode.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.07)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .strokeBorder(.black.opacity(0.08))
        )
    }
}
