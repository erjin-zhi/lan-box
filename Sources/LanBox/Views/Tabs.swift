import SwiftUI

// MARK: - 文件

struct FilesTab: View {
    @ObservedObject var model: AppModel
    var dropTargeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            dropZone
            if model.items.isEmpty {
                EmptyState(
                    symbol: "square.dashed",
                    title: "还没有共享任何文件",
                    message: "拖进来的文件才会出现在共享网页上。设备上传的文件也会显示在这里。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in FileRow(model: model, item: item) }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 10) {
            Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "plus.circle")
                .font(.system(size: 18))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(dropTargeted ? "松开即可加入共享" : "拖到这里，或拷贝后按 ⌘V")
                    .font(.callout.weight(.medium))
                Text(model.addMode == .link ? "以替身方式加入，不会复制原文件" : "会拷贝一份到共享文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("选择…", action: model.pickFilesToAdd)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(dropTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }
}

struct FileRow: View {
    @ObservedObject var model: AppModel
    let item: SharedItem

    var body: some View {
        HoverRow {
            Image(nsImage: NSWorkspace.shared.icon(forFile: (item.target ?? item.url).path))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(item.isBroken ? 0.4 : 1)
                .overlay(alignment: .bottomLeading) {
                    if item.isLink {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white, .secondary)
                            .offset(x: -2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if model.isRecentlyReceived(item) {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                            .help("最近收到的文件")
                    }
                    Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let added = item.added {
                        Text(Fmt.relative(added))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(model.isRecentlyReceived(item) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .help(Fmt.fullDate(added))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(item.isBroken ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            if !item.isBroken {
                RowIconButton(symbol: "magnifyingglass", help: "在 Finder 中显示") { model.reveal(item) }
            }
            RowIconButton(symbol: item.isLink ? "minus.circle" : "trash", help: item.isLink ? "停止共享（不影响原文件）" : "移到废纸篓") {
                model.remove(item)
            }
        }
        .contextMenu {
            Button("拷贝") { model.copyToClipboard(item) }.disabled(item.isBroken)
            Button("在 Finder 中显示") { model.reveal(item) }.disabled(item.isBroken)
            Divider()
            if item.isLink {
                Button("停止共享") { model.remove(item) }
            } else {
                Button("移到废纸篓", role: .destructive) { model.remove(item) }
            }
        }
    }

    private var subtitle: String {
        if item.isBroken { return "原文件已被移动或删除" }
        var parts: [String] = []
        if let from = item.from { parts.append("来自 \(from)") }
        else if item.isLink { parts.append("替身") }
        switch item.kind {
        case .folder: parts.append("文件夹，下载时自动打包")
        case .package: parts.append("应用 / 文件包，下载时自动打包")
        case .file: if let size = item.size { parts.append(Fmt.bytes(size)) }
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - 设备

struct DevicesTab: View {
    @ObservedObject var model: AppModel
    /// 主窗口左栏已经常驻星图，这里不再重复。
    var showsOrbit = true

    var body: some View {
        VStack(spacing: 4) {
            if showsOrbit { OrbitView(model: model) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.clients.isEmpty {
                        Text("让手机扫描上方二维码，或在浏览器中输入地址。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                    }
                    ForEach(model.clients.filter(\.isOnline)) { DeviceRow(model: model, client: $0) }
                    let recent = model.clients.filter { !$0.isOnline }
                    if !recent.isEmpty {
                        Text("最近访问")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                        ForEach(recent) { DeviceRow(model: model, client: $0).opacity(0.65) }
                    }
                }
            }
        }
    }
}

struct DeviceRow: View {
    @ObservedObject var model: AppModel
    let client: ClientInfo

    var body: some View {
        HoverRow {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(.fill.tertiary)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: client.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(client.isOnline ? .primary : .tertiary)
                    }
                StatusDot(color: dotColor, size: 9)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(client.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(client.platform) · \(client.browser)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Text(statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } actions: {
            Text(client.ip).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .contextMenu {
            if client.blocked {
                Button("允许访问") { model.setBlocked(client, false) }
            } else {
                Button("阻止此设备", role: .destructive) { model.setBlocked(client, true) }
            }
            Button("从列表中移除") { model.forget(client) }
        }
    }

    private var dotColor: Color {
        if client.blocked { return .red }
        if !client.isOnline { return Color(nsColor: .tertiaryLabelColor) }
        if !client.authorized { return .orange }
        return client.visible ? .green : .yellow
    }

    private var statusLine: String {
        if client.blocked { return "已阻止访问" }
        if !client.authorized {
            return client.isOnline ? "正在输入访问码" : "未输入访问码就离开了 · \(Fmt.relative(client.lastSeen))"
        }
        if let t = model.activeTransfers.first(where: { $0.clientID == client.id }) {
            let pct = t.fraction.map { " \(Int($0 * 100))%" } ?? ""
            return (t.direction == .upload ? "正在上传 " : "正在下载 ") + t.name + pct
        }
        if !client.isOnline { return "已离开 · \(Fmt.relative(client.lastSeen))" }
        return client.visible ? client.activity : "网页在后台（锁屏或切到了其他应用）"
    }
}

// MARK: - 传输

struct TransfersTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.transfers.isEmpty {
            EmptyState(
                symbol: "arrow.up.arrow.down",
                title: "没有传输记录",
                message: "设备下载或上传文件时，进度和速度会显示在这里。"
            )
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清除已完成", action: model.clearFinishedTransfers)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(model.transfers.allSatisfy { $0.state == .active })
                }
                .padding(.horizontal, 10)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.transfers) { t in TransferRow(transfer: t) }
                    }
                }
            }
        }
    }

    private var summary: String {
        let active = model.activeTransfers
        guard !active.isEmpty else { return "共 \(model.transfers.count) 条记录" }
        let speed = active.reduce(0) { $0 + $1.speed }
        return "\(active.count) 项进行中 · \(Fmt.speed(speed))"
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        let state = transfer.state
        HoverRow {
            Image(systemName: icon(state))
                .font(.system(size: 20))
                .foregroundStyle(tint(state))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(transfer.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(transfer.direction == .upload ? "来自 \(transfer.clientName)" : "发给 \(transfer.clientName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if state == .active {
                    if let f = transfer.fraction {
                        ProgressView(value: f).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Text(detail(state)).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
        } actions: {
            if state == .active {
                RowIconButton(symbol: "xmark.circle.fill", help: "停止传输") { transfer.cancel() }
            }
        }
    }

    private func icon(_ state: Transfer.State) -> String {
        switch state {
        case .active: return transfer.direction == .upload ? "arrow.down.circle" : "arrow.up.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func tint(_ state: Transfer.State) -> Color {
        switch state {
        case .active: return .accentColor
        case .completed: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        }
    }

    private func detail(_ state: Transfer.State) -> String {
        let done = transfer.done
        switch state {
        case .active:
            var s = transfer.total.map { "\(Fmt.bytes(done)) / \(Fmt.bytes(max($0, done)))" } ?? Fmt.bytes(done)
            s += " · \(Fmt.speed(transfer.speed))"
            if let total = transfer.total, let eta = Fmt.remaining(done: done, total: total, speed: transfer.speed) { s += " · 剩余\(eta)" }
            return s
        case .completed:
            return "\(Fmt.bytes(done)) · 平均 \(Fmt.speed(transfer.speed)) · \(Fmt.relative(transfer.ended ?? Date()))"
        case .failed:
            return "已中断 · 传了 \(Fmt.bytes(done))"
        case .cancelled:
            return "已停止 · 传了 \(Fmt.bytes(done))"
        }
    }
}
