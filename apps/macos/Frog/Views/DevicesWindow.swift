import SwiftUI

/// Where frog can run models, drawn as a map: this Mac at the top, the tang nodes it found on
/// the network and Frog Cloud below it, each linked by how it's reached. Cards are live: free
/// memory, the loaded model, measured decode tok/s and the queue, from each node's `/node`.
struct DevicesWindow: View {
    static let id = "devices"
    @State private var devices = Devices.shared

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    DotGrid()
                    TopologyMap(devices: devices.list, size: geo.size)
                    if let problem = devices.browseProblem {
                        Text(problem)
                            .font(.frog(size: 12))
                            .foregroundStyle(Tokens.signal)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Tokens.raised))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                    }
                }
            }
            PoolSummary(devices: devices.list)
        }
        .background(FrogCanvas.color)
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
        .frame(minWidth: 640, minHeight: 440)
    }
}

/// The cards and the links between them.
private struct TopologyMap: View {
    let devices: [Device]
    let size: CGSize

    private static let card = CGSize(width: 236, height: 176)
    private static let gap: CGFloat = 28

    private var root: Device? { devices.first { $0.role == .thisMac } }
    private var children: [Device] { devices.filter { $0.role != .thisMac } }

    private var rootCenter: CGPoint {
        CGPoint(x: size.width / 2, y: max(Self.card.height / 2 + 32, size.height * 0.28))
    }

    private func childCenter(_ i: Int) -> CGPoint {
        let n = CGFloat(children.count)
        let w = Self.card.width + Self.gap
        let x = size.width / 2 + (CGFloat(i) - (n - 1) / 2) * w
        let y = min(size.height - Self.card.height / 2 - 40, rootCenter.y + Self.card.height + 84)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            ForEach(Array(children.enumerated()), id: \.element.id) { i, d in
                Link(from: rootCenter, to: childCenter(i), card: Self.card, live: d.online, label: d.link.label)
            }
            if let root {
                DeviceCard(device: root)
                    .frame(width: Self.card.width, height: Self.card.height)
                    .position(rootCenter)
            }
            ForEach(Array(children.enumerated()), id: \.element.id) { i, d in
                DeviceCard(device: d)
                    .frame(width: Self.card.width, height: Self.card.height)
                    .position(childCenter(i))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if !children.contains(where: { $0.role == .node }) {
                Text("Run `tang-llm serve --host 0.0.0.0` on any Mac or GPU box on your network to add it.")
                    .font(.frog(size: 12))
                    .foregroundStyle(Tokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .position(x: size.width / 2, y: min(size.height - 16, childCenter(0).y + Self.card.height / 2 + 24))
            }
        }
        .animation(.snappy(duration: 0.3), value: devices.map(\.id))
    }
}

/// An elbow from the bottom of one card to the top of another, with how it's reached on it.
private struct Link: View {
    let from: CGPoint
    let to: CGPoint
    let card: CGSize
    let live: Bool
    let label: String

    var body: some View {
        let a = CGPoint(x: from.x, y: from.y + card.height / 2)
        let b = CGPoint(x: to.x, y: to.y - card.height / 2)
        let midY = (a.y + b.y) / 2
        ZStack {
            Path { p in
                p.move(to: a)
                p.addLine(to: CGPoint(x: a.x, y: midY - 10))
                if abs(b.x - a.x) > 1 {
                    let dir: CGFloat = b.x > a.x ? 1 : -1
                    p.addQuadCurve(to: CGPoint(x: a.x + 10 * dir, y: midY), control: CGPoint(x: a.x, y: midY))
                    p.addLine(to: CGPoint(x: b.x - 10 * dir, y: midY))
                    p.addQuadCurve(to: CGPoint(x: b.x, y: midY + 10), control: CGPoint(x: b.x, y: midY))
                }
                p.addLine(to: b)
            }
            .stroke(live ? Tokens.textTertiary : Tokens.textQuaternary,
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: live ? [] : [3, 4]))
            Text(label)
                .font(.frog(size: 10, weight: .medium))
                .foregroundStyle(Tokens.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Tokens.raised))
                .position(x: b.x, y: midY)
        }
        .allowsHitTesting(false)
    }
}

/// One machine: what it is, how much memory it has free, what it's running and how fast.
private struct DeviceCard: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if device.role == .thisMac {
                Text("This Mac")
                    .font(.frog(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Tokens.hover)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.textSecondary)
                    Text(device.name)
                        .font(.frog(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                        .help(status)
                }
                Text(spec)
                    .font(.frog(size: 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                MemoryBar(device: device)
                Spacer(minLength: 0)
                running
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tokens.raised))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .monospacedDigit()
    }

    private var symbol: String {
        switch device.role {
        case .thisMac: device.symbol
        case .cloud: "cloud"
        case .node: device.kind == "metal" ? "desktopcomputer" : "server.rack"
        }
    }

    private var spec: String {
        switch device.role {
        case .cloud: return "Hosted · \(device.chip)"
        default:
            let mem = device.totalBytes > 0 ? "\(gb(device.totalBytes)) \(device.unified ? "unified" : "VRAM")" : ""
            return [device.chip, mem].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private var dot: Color {
        guard device.online else { return Tokens.textQuaternary }
        return device.running + device.waiting > 0 ? Tokens.signal : Tokens.accent
    }

    private var status: String {
        if device.role == .cloud { return device.online ? "Signed in" : "Not signed in" }
        if device.keyed && device.model == nil { return "Found on the network; needs pairing" }
        if !device.online { return device.role == .thisMac ? "Engine not running" : "Not answering" }
        if device.running > 0 { return "Working" + (device.waiting > 0 ? ", \(device.waiting) waiting" : "") }
        return "Ready"
    }

    @ViewBuilder private var running: some View {
        if device.role == .cloud {
            HStack(alignment: .firstTextBaseline) {
                Text(device.online ? "Ready" : "Sign in in Settings")
                    .font(.frog(size: 12))
                    .foregroundStyle(device.online ? Tokens.text : Tokens.textTertiary)
                Spacer()
                Text("pay per token")
                    .font(.frog(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            }
        } else if device.keyed && device.model == nil {
            Text("Needs pairing")
                .font(.frog(size: 12))
                .foregroundStyle(Tokens.textTertiary)
        } else if let model = device.loading ?? device.model {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.loading != nil ? "Loading" : "Loaded")
                        .font(.frog(size: 10))
                        .foregroundStyle(Tokens.textTertiary)
                    Text(model)
                        .font(.frog(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let tps = device.decode {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(tps < 10 ? String(format: "%.1f", tps) : "\(Int(tps.rounded()))")
                            .font(.frog(size: 20, weight: .semibold))
                        Text("tok/s")
                            .font(.frog(size: 10))
                            .foregroundStyle(Tokens.textTertiary)
                    }
                }
            }
        } else {
            Text(device.online ? "No model loaded" : status)
                .font(.frog(size: 12))
                .foregroundStyle(Tokens.textTertiary)
        }
    }
}

/// How much of the machine's memory is spoken for.
private struct MemoryBar: View {
    let device: Device

    var body: some View {
        if device.role == .cloud {
            Color.clear.frame(height: 18)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.hover)
                        Capsule()
                            .fill(Tokens.textTertiary)
                            .frame(width: geo.size.width * (device.usedFraction ?? 0))
                    }
                }
                .frame(height: 4)
                Text(device.freeBytes.map { "\(gb($0)) free" } ?? " ")
                    .font(.frog(size: 10))
                    .foregroundStyle(Tokens.textTertiary)
            }
            .animation(.smooth(duration: 0.4), value: device.usedFraction)
        }
    }
}

/// The pool in one line: how many machines, how much memory, the fastest one right now.
private struct PoolSummary: View {
    let devices: [Device]

    var body: some View {
        let local = devices.filter { $0.role != .cloud }
        let up = local.filter { $0.online || $0.role == .thisMac }
        let memory = up.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let fastest = devices.compactMap(\.decode).max()
        HStack(spacing: 18) {
            stat("\(up.count)", up.count == 1 ? "machine" : "machines")
            stat(gb(memory), "pooled memory")
            stat(fastest.map { "\(Int($0.rounded()))" } ?? "–", "tok/s fastest")
            Spacer()
            if devices.contains(where: { $0.role == .cloud && $0.online }) {
                Text("Frog Cloud picks up what the pool can't fit")
                    .font(.frog(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Tokens.sidebar)
        .monospacedDigit()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.frog(size: 13, weight: .semibold))
            Text(label).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
        }
    }
}

/// The canvas's faint dot grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var path = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += step
                }
                y += step
            }
            ctx.fill(path, with: .color(Tokens.textQuaternary.opacity(0.6)))
        }
        .allowsHitTesting(false)
    }
}

private func gb(_ bytes: UInt64) -> String {
    let g = Double(bytes) / 1_073_741_824
    return g >= 10 ? "\(Int(g.rounded())) GB" : String(format: "%.1f GB", g)
}
