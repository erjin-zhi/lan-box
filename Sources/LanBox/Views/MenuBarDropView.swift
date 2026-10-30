import SwiftUI

@MainActor
final class MenuBarDropState: ObservableObject {
    @Published var isTargeted = false
    @Published var isReceiving = false
    @Published var fileCount = 1
}

/// 只负责投放反馈；拖放由外层 AppKit 视图接收，避免抢走 Finder 的拖拽会话。
struct MenuBarDropView: View {
    @ObservedObject var state: MenuBarDropState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    private var accent: Color {
        state.isTargeted ? Color(red: 0.25, green: 0.66, blue: 0.86) : Color(red: 0.48, green: 0.62, blue: 0.70)
    }

    private var opening: CGFloat {
        state.isReceiving || !appeared ? 0 : (state.isTargeted ? 1 : 0.65)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("LanBox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            box
                .frame(width: 150, height: 120)
                .scaleEffect(reduceMotion || appeared ? 1 : 0.92, anchor: .top)
            Text(state.isReceiving ? "正在加入共享…" : (state.isTargeted ? "松手，放进盒子" : "拖进盒子，即可共享"))
                .font(.system(size: 14, weight: .semibold))
            Text(state.fileCount > 1 ? "\(state.fileCount) 个项目" : "文件和文件夹")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: 244, height: 212)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(accent.opacity(state.isTargeted ? 0.09 : 0.025))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(state.isTargeted ? accent.opacity(0.65) : Color.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 7, y: 3)
        }
        .frame(width: 264, height: 232)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: state.isTargeted)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: state.isReceiving)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) { appeared = true }
        }
        .accessibilityElement(children: .combine)
    }

    private var box: some View {
        ZStack {
            Ellipse()
                .fill(accent.opacity(0.16))
                .frame(width: 100, height: 12)
                .blur(radius: 5)
                .offset(y: 48)

            // 后盖先展开，文件位于盒口和前侧盒身之间。
            DropBoxFlap(opening: opening, isLeft: true)
                .fill(accent.opacity(0.23))
                .overlay { DropBoxFlap(opening: opening, isLeft: true).stroke(accent.opacity(0.75), style: edgeStyle) }
            DropBoxFlap(opening: opening, isLeft: false)
                .fill(accent.opacity(0.33))
                .overlay { DropBoxFlap(opening: opening, isLeft: false).stroke(accent.opacity(0.75), style: edgeStyle) }
            polygon([(31, 60), (75, 39), (119, 60), (75, 81)])
                .fill(colorScheme == .dark ? Color(red: 0.13, green: 0.19, blue: 0.22) : Color(red: 0.70, green: 0.79, blue: 0.83))

            Image(systemName: state.fileCount > 1 ? "doc.on.doc.fill" : "doc.fill")
                .font(.system(size: 35, weight: .regular))
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.91) : .white)
                .shadow(color: accent.opacity(0.35), radius: 4, y: 2)
                .rotationEffect(.degrees(state.isReceiving ? 0 : (state.isTargeted ? -5 : -11)))
                .offset(y: state.isReceiving ? 14 : (state.isTargeted ? -25 : -20))
                .scaleEffect(state.isReceiving ? 0.55 : 1)
                .opacity(state.isReceiving ? 0 : 1)

            polygon([(31, 60), (75, 81), (75, 113), (31, 92)])
                .fill(LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                .overlay { polygon([(31, 60), (75, 81), (75, 113), (31, 92)]).stroke(accent, style: edgeStyle) }
            polygon([(75, 81), (119, 60), (119, 92), (75, 113)])
                .fill(LinearGradient(colors: [accent.opacity(0.68), accent.opacity(0.48)], startPoint: .top, endPoint: .bottom))
                .overlay { polygon([(75, 81), (119, 60), (119, 92), (75, 113)]).stroke(accent, style: edgeStyle) }
            Path { path in
                path.move(to: CGPoint(x: 43, y: 81))
                path.addLine(to: CGPoint(x: 58, y: 88))
            }
            .stroke(.white.opacity(0.72), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .scaleEffect(state.isTargeted && !state.isReceiving ? 1.045 : 1)
        .accessibilityHidden(true)
    }

    private var edgeStyle: StrokeStyle { StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round) }

    private func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
    }
}

/// 两片盒盖共享盒口边缘，开合时外沿往两侧翻开。
private struct DropBoxFlap: Shape {
    var opening: CGFloat
    let isLeft: Bool

    var animatableData: CGFloat {
        get { opening }
        set { opening = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let sign: CGFloat = isLeft ? -1 : 1
        let outerX = 75 + sign * 44
        let reach = 24 * opening
        let rise = 18 * opening
        var path = Path()
        path.move(to: CGPoint(x: outerX, y: 60))
        path.addLine(to: CGPoint(x: 75, y: 39))
        path.addLine(to: CGPoint(x: 75 + sign * reach, y: 39 - rise))
        path.addLine(to: CGPoint(x: outerX + sign * reach, y: 60 - rise))
        path.closeSubpath()
        return path
    }
}
