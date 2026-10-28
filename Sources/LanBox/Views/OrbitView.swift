import SwiftUI

/// 设备星图：Mac 居中，在线设备沿椭圆轨道缓慢环绕。
/// 传输时设备与 Mac 之间有光点流动；传输完成会在设备旁冒出文件气泡。
struct OrbitView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = OrbitMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            GeometryReader { geo in
                scene(size: geo.size, now: timeline.date)
            }
        }
        .frame(height: 178)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.onlineClients.isEmpty ? "没有设备在线" : "\(model.onlineClients.count) 台设备在线")
    }

    // MARK: 场景

    private struct Placed {
        let client: ClientInfo
        let point: CGPoint
        let depth: Double     // -1 远（上方）… 1 近（下方）
        let scale: Double
        let opacity: Double
        let joinAge: Double?
    }

    @ViewBuilder
    private func scene(size: CGSize, now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let center = CGPoint(x: size.width / 2, y: size.height / 2 - 6)
        let rx = min(size.width / 2 - 46, 152.0)
        let ry = rx * 0.36
        let placed = place(center: center, rx: rx, ry: ry, now: now, t: t)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.client.id, $0) })
        let active = model.activeTransfers
        let macBump = macBump(now: now)

        ZStack {
            Canvas { g, _ in
                drawOrbit(g, center: center, rx: rx, ry: ry, empty: placed.isEmpty)
                if model.isRunning { drawRipples(g, center: center, t: t) }
                for p in placed {
                    if let age = p.joinAge, age < 0.9 { drawJoinRipple(g, at: p.point, age: age) }
                }
                for tr in active {
                    guard let p = byID[tr.clientID] else { continue }
                    let (from, to) = tr.direction == .upload ? (p.point, center) : (center, p.point)
                    drawStream(g, from: from, to: to, t: t, seed: Double(abs(tr.id.hashValue % 97)) / 97)
                }
            }

            ForEach(placed, id: \.client.id) { p in
                let tr = active.first { $0.clientID == p.client.id }
                OrbitNode(client: p.client, progress: tr?.fraction, transferring: tr != nil)
                    .scaleEffect(p.scale)
                    .opacity(p.opacity)
                    .position(x: p.point.x, y: p.point.y + 8 * p.scale)
                    .zIndex(p.depth * 10)
            }

            MacNode(isLaptop: model.isLaptop, running: model.isRunning)
                .scaleEffect(1 + macBump)
                .position(center)
                .zIndex(0)

            ForEach(bubbles(byID: byID, center: center, width: size.width, now: now)) { b in
                FileBubble(name: b.name, direction: b.direction)
                    .scaleEffect(b.scale)
                    .opacity(b.opacity)
                    .position(b.point)
                    .zIndex(20)
            }

            if placed.isEmpty {
                Text(model.isRunning ? "扫描二维码后，设备会出现在轨道上" : "开启共享后，设备才能连接")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .position(x: center.x, y: size.height - 10)
            }
        }
    }

    private func place(center: CGPoint, rx: Double, ry: Double, now: Date, t: Double) -> [Placed] {
        let online = model.onlineClients
        let angles = motion.angles(for: online.map(\.id), leaving: Array(model.leavers.keys), t: t, spin: !reduceMotion)
        var result: [Placed] = []

        func make(_ c: ClientInfo, angle: Double, scaleFactor: Double, opacity: Double, joinAge: Double?) -> Placed {
            let depth = sin(angle)
            let point = CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * depth)
            let perspective = 0.82 + 0.18 * (depth + 1) / 2
            let fade = 0.75 + 0.25 * (depth + 1) / 2
            return Placed(client: c, point: point, depth: depth, scale: perspective * scaleFactor,
                          opacity: fade * opacity, joinAge: joinAge)
        }

        for c in online {
            guard let a = angles[c.id] else { continue }
            let age = model.joinTimes[c.id].map { now.timeIntervalSince($0) }
            let s = age.map { Ease.outBack(min(1, $0 / 0.55)) } ?? 1
            result.append(make(c, angle: a, scaleFactor: s, opacity: min(1, (age ?? 1) / 0.25), joinAge: age))
        }
        for (id, leaver) in model.leavers {
            guard let a = angles[id] else { continue }
            let k = max(0, 1 - now.timeIntervalSince(leaver.date) / 0.6)
            if k > 0 { result.append(make(leaver.client, angle: a, scaleFactor: 0.4 + 0.6 * k, opacity: k, joinAge: nil)) }
        }
        return result
    }

    // MARK: 气泡

    private struct Bubble: Identifiable {
        let id: UUID
        let name: String
        let direction: Transfer.Direction
        let point: CGPoint
        let scale: Double
        let opacity: Double
    }

    private func bubbles(byID: [String: Placed], center: CGPoint, width: Double, now: Date) -> [Bubble] {
        var stackIndex: [String: Int] = [:]
        var result: [Bubble] = []
        for e in model.orbitEvents {
            guard let p = byID[e.clientID] else { continue }
            let k = stackIndex[e.clientID, default: 0]
            stackIndex[e.clientID] = k + 1
            // 气泡最宽约 120pt，靠边时往里收，避免被裁掉
            let anchor = CGPoint(x: min(max(p.point.x + 10, 64), width - 64),
                                 y: max(12, p.point.y - 26 * p.scale - Double(k) * 20))
            let age = now.timeIntervalSince(e.date)
            var point = anchor, scale = 1.0, opacity = 1.0

            if e.direction == .upload {
                // 在设备旁冒出 → 停留 → 飞进 Mac
                if age < 0.35 {
                    scale = Ease.outBack(age / 0.35)
                } else if age > 2.2 {
                    let f = Ease.inOut(min(1, (age - 2.2) / 0.7))
                    point = Ease.lerp(anchor, center, f)
                    scale = 1 - 0.6 * f
                    opacity = 1 - f * f
                }
            } else {
                // 从 Mac 飞出 → 落到设备旁 → 消失
                if age < 0.7 {
                    let f = Ease.inOut(age / 0.7)
                    point = Ease.lerp(center, anchor, f)
                    scale = 0.4 + 0.6 * f
                    opacity = min(1, f * 2)
                } else if age > 2.6 {
                    opacity = max(0, 1 - (age - 2.6) / 0.6)
                }
            }
            if opacity > 0.01 {
                result.append(Bubble(id: e.id, name: e.fileName, direction: e.direction, point: point, scale: scale, opacity: opacity))
            }
        }
        return result
    }

    /// 上传的文件被 Mac “吸收”时轻轻弹一下。
    private func macBump(now: Date) -> Double {
        var bump = 0.0
        for e in model.orbitEvents where e.direction == .upload {
            let age = now.timeIntervalSince(e.date) - 2.75
            if age > 0, age < 0.4 { bump = max(bump, 0.12 * sin(age / 0.4 * .pi)) }
        }
        return bump
    }

    // MARK: 绘制

    private func drawOrbit(_ g: GraphicsContext, center: CGPoint, rx: Double, ry: Double, empty: Bool) {
        let ring = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2))
        g.stroke(ring, with: .color(.secondary.opacity(0.32)),
                 style: StrokeStyle(lineWidth: 1, dash: empty ? [3, 4] : []))
        let outer = Path(ellipseIn: CGRect(x: center.x - rx * 1.13, y: center.y - ry * 1.3, width: rx * 2.26, height: ry * 2.6))
        g.stroke(outer, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
    }

    private func drawRipples(_ g: GraphicsContext, center: CGPoint, t: Double) {
        guard !reduceMotion else { return }
        for k in 0..<2 {
            let phase = (t / 3.2 + Double(k) / 2).truncatingRemainder(dividingBy: 1)
            let r = 27 + 30 * phase
            let path = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r * 0.8, width: r * 2, height: r * 1.6))
            g.stroke(path, with: .color(.green.opacity(0.28 * (1 - phase))), lineWidth: 1.2)
        }
    }

    private func drawJoinRipple(_ g: GraphicsContext, at p: CGPoint, age: Double) {
        let f = age / 0.9
        let r = 18 + 26 * Ease.out(f)
        g.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .color(.accentColor.opacity(0.5 * (1 - f))), lineWidth: 1.5)
    }

    private func drawStream(_ g: GraphicsContext, from: CGPoint, to: CGPoint, t: Double, seed: Double) {
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        g.stroke(line, with: .color(.accentColor.opacity(0.16)), lineWidth: 1.5)
        let count = 4
        for i in 0..<count {
            let phase = reduceMotion
                ? Double(i + 1) / Double(count + 1)
                : (t * 0.9 + seed + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
            let p = Ease.lerp(from, to, phase)
            let alpha = sin(phase * .pi)
            let r = 2.4
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .color(.accentColor.opacity(alpha)))
        }
    }
}

// MARK: - 节点

private struct OrbitNode: View {
    let client: ClientInfo
    let progress: Double?
    let transferring: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                Circle().strokeBorder(.separator, lineWidth: 0.5)
                Image(systemName: client.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                if let progress {
                    Circle()
                        .trim(from: 0, to: max(0.02, progress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-3)
                } else if transferring {
                    Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 2).padding(-3)
                }
            }
            .frame(width: 34, height: 34)
            .opacity(client.visible ? 1 : 0.5)
            .overlay(alignment: .topTrailing) {
                if !client.visible {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .offset(x: 3, y: -3)
                }
            }

            Text(client.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 86)
        }
        .help(client.visible ? client.name : "\(client.name)：网页在后台")
    }
}

private struct MacNode: View {
    let isLaptop: Bool
    let running: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .labelColor))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            Image(systemName: isLaptop ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 50, height: 50)
        .opacity(running ? 1 : 0.45)
    }
}

private struct FileBubble: View {
    let name: String
    let direction: Transfer.Direction

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: FileBubble.symbol(for: name))
                .font(.system(size: 9, weight: .bold))
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(direction == .upload ? Color.accentColor : Color.green))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .frame(maxWidth: 120)
        .fixedSize()
        .frame(maxWidth: 120)
    }

    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "raw", "dng": return "photo.fill"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return "film.fill"
        case "mp3", "m4a", "wav", "aac", "flac", "aiff": return "waveform"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z", "gz", "tar", "dmg": return "archivebox.fill"
        case "app", "apk", "ipa", "exe", "pkg": return "app.fill"
        default: return "doc.fill"
        }
    }
}

// MARK: - 运动

/// 设备在轨道上的角度。设备增减时平滑滑到新位置，而不是跳变。
final class OrbitMotion {
    private var offsets: [String: Double] = [:]
    private var lastTime: Double?

    func angles(for ids: [String], leaving: [String], t: Double, spin: Bool) -> [String: Double] {
        let dt = lastTime.map { min(0.1, max(0, t - $0)) } ?? 1
        lastTime = t
        let spinAngle = spin ? t * 2 * .pi / 90 : 0
        let n = max(ids.count, 1)
        var result: [String: Double] = [:]
        for (i, id) in ids.enumerated() {
            // 第一台设备放在正前方（下方）
            let target = .pi / 2 + Double(i) / Double(n) * 2 * .pi
            var current = offsets[id] ?? target
            var diff = (target - current).truncatingRemainder(dividingBy: 2 * .pi)
            if diff > .pi { diff -= 2 * .pi } else if diff < -.pi { diff += 2 * .pi }
            current += diff * min(1, dt * 3.5)
            offsets[id] = current
            result[id] = current + spinAngle
        }
        for id in leaving {
            if let o = offsets[id] { result[id] = o + spinAngle }
        }
        let keep = Set(ids).union(leaving)
        offsets = offsets.filter { keep.contains($0.key) }
        return result
    }
}

enum Ease {
    static func out(_ x: Double) -> Double { 1 - pow(1 - min(max(x, 0), 1), 3) }
    static func inOut(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func outBack(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}
