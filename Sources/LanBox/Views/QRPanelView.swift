import SwiftUI

/// 独立的大二维码窗口，方便放在屏幕上让多台手机扫码。
struct QRPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                AppMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.hostName).font(.headline)
                    Text(model.isRunning ? "正在共享 \(model.folderDisplayName)" : "已停止共享")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let link = model.shareLink {
                QRImage(text: link, size: 300)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)

                VStack(spacing: 6) {
                    Text("用手机相机扫描，即可打开共享页面")
                        .font(.callout)
                    Text(model.displayAddress ?? "")
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                    if model.requirePIN {
                        Text("手动输入地址时需要访问码 \(model.pin)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("暂时无法访问", systemImage: "wifi.slash",
                                       description: Text("请开启共享，并确认 Mac 已连接到局域网。"))
                    .frame(height: 380)
            }

            HStack {
                if model.interfaces.count > 1 {
                    Picker("网络", selection: Binding(get: { model.selectedInterface?.id }, set: { model.selectedInterfaceID = $0 })) {
                        ForEach(model.interfaces) { Text("\($0.displayName)  \($0.address)").tag(Optional($0.id)) }
                    }
                    .fixedSize()
                }
                Spacer()
                Button("拷贝链接", systemImage: "doc.on.doc", action: model.copyLink)
                    .buttonStyle(.glass)
                    .disabled(model.shareLink == nil)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 420)
    }
}
