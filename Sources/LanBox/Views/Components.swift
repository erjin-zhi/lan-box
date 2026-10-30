import SwiftUI

struct AppMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color(nsColor: .labelColor))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "shippingbox")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
    }
}

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// 列表中的内容卡片底色：内容层使用实色填充，玻璃材质只留给控件。
struct CardBackground: ViewModifier {
    var radius: CGFloat = 16

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.fill.quaternary)
        )
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardBackground(radius: radius)) }
}

/// 列表行：悬停时显示操作按钮，并有轻微的高亮底色。
struct HoverRow<Content: View, Actions: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 4)
            actions()
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct RowIconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 底部浮出的简短提示（拷贝、粘贴之后的反馈）。
struct NoticeBanner: View {
    let text: String?

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
        .allowsHitTesting(false)
    }
}

/// 系统通知被关闭时的提示：收到文件仍会有 Dock 角标和 App 内提示，但不会弹出横幅。
struct NotificationsOffHint: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.notificationsBlocked && (model.notifyUploads || model.notifyNewDevices) {
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("系统通知已关闭").font(.caption.weight(.semibold))
                    Text("收到文件时不会弹出提醒").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("打开设置", action: model.openNotificationSettings)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(10)
            .card(radius: 12)
        }
    }
}
