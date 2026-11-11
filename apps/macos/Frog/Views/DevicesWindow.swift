import SwiftUI

/// Where frog can run models, as a map: this Mac in the middle, Frog Cloud above it, the tang
/// nodes it found on the network around it, each linked by how it's reached. Cards are live
/// (free memory, the loaded model, measured tok/s, the queue, from each node's `/node`), and
/// the link serving this turn is lit and flowing.
///
/// The same map shows in two places: a popover from the composer's chip (`DeviceChip`), and
/// the Devices window (Window → Devices), its full-size version.
struct DevicesWindow: View {
    static let id = "devices"
    @State private var devices = Devices.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                DotGrid()
                DeviceMap(devices: devices.list, serving: nil, live: false, compact: false)
                    .padding(24)
                if let problem = devices.browseProblem { ProblemLine(text: problem).padding(.top, 12) }
            }
            PoolSummary(devices: devices.list)
        }
        .background(FrogCanvas.color)
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
        .frame(minWidth: 640, minHeight: 460)
    }
}

/// The composer's "on mew · 58 tok/s": where this session's model runs, always in view. Its dot
/// breathes while a turn streams; a click opens the map.
struct DeviceChip: View {
    let conversation: Conversation
    @State private var devices = Devices.shared
    @State private var open = false

    var body: some View {
        if let status = conversation.status {
            let serving = devices.serving(model: status.model, ranOn: status.ranOn)
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    BreathingDot(live: conversation.busy)
                    Image(systemName: serving.symbol)
                    Text("on \(serving.name)")
                        .lineLimit(1)
                    if let tps = status.tokensPerSec, tps > 0 {
                        Text("· " + ModelStats.speedText(tps))
                            .foregroundStyle(Tokens.textTertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(open ? Tokens.raised : Color.clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Where this model runs. Click for the map of your machines.")
            .popover(isPresented: $open, arrowEdge: .top) {
                DeviceMapPopover(serving: serving, live: conversation.busy, tps: status.tokensPerSec)
            }
        }
    }
}

/// The map from the chip: the pool in a header line, the map, how frog picks below.
private struct DeviceMapPopover: View {
    let serving: Serving
    let live: Bool
    let tps: Double?
    @State private var devices = Devices.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where frog runs")
                    .font(.frog(size: 13, weight: .semibold))
                Spacer()
                Text(PoolSummary.line(devices.list))
                    .font(.frog(size: 11))
                    .foregroundStyle(Tokens.textTertiary)
                    .monospacedDigit()
            }
            if let problem = devices.browseProblem { ProblemLine(text: problem) }
            DeviceMap(devices: devices.list, serving: serving.deviceID, live: live, compact: true, servingRate: tps)
                // One row until nodes fan out above and below.
                .frame(height: devices.list.filter { $0.role == .node }.count > 1 ? 280 : 150)
            HStack {
                Text("\(serving.model) on \(serving.name)")
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open map") { openWindow(id: DevicesWindow.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.textSecondary)
            }
            .font(.frog(size: 11))
        }
        .padding(14)
        .frame(width: 600)
        .background(FrogCanvas.color)
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
    }
}

/// This Mac in the middle, Frog Cloud above, nodes around the lower arc.
private struct DeviceMap: View {
    let devices: [Device]
    /// The device serving this session, lit on the map.
    let serving: String?
    /// A turn is streaming: the serving link flows.
    let live: Bool
    let compact: Bool
    var servingRate: Double? = nil

    private var card: CGSize { compact ? CGSize(width: 150, height: 96) : CGSize(width: 236, height: 168) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let placed = layout(in: size)
            ZStack {
                ForEach(placed, id: \.0.id) { d, p in
                    MapLink(from: center, to: p,
                            lit: d.id == serving, live: live && d.id == serving,
                            online: d.online,
                            label: linkLabel(d))
                }
                if let root = devices.first(where: { $0.role == .thisMac }) {
                    DeviceCard(device: root, compact: compact, serving: root.id == serving)
                        .frame(width: card.width, height: card.height)
                        .position(center)
                }
                ForEach(placed, id: \.0.id) { d, p in
                    DeviceCard(device: d, compact: compact, serving: d.id == serving)
                        .frame(width: card.width, height: card.height)
                        .position(p)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if !compact, !devices.contains(where: { $0.role == .node }) {
                    Text("Run `curl -fsSL https://frog.toys/node | sh` on any Linux GPU box on your network, or turn on Settings › Lend on another Mac, to add it.")
                        .font(.frog(size: 12))
                        .foregroundStyle(Tokens.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .position(x: center.x, y: size.height - 10)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: devices.map(\.id))
    }

    /// Frog Cloud to the right; nodes fan out over the left (one straight across, more spreading
    /// up and down), spilling over the top and bottom past four. Wide, like the windows it sits in.
    private func layout(in size: CGSize) -> [(Device, CGPoint)] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = max(card.width * 1.25, size.width / 2 - card.width / 2 - 4)
        let ry = max(0, size.height / 2 - card.height / 2 - 4)
        let at = { (deg: Double) in
            CGPoint(x: center.x + rx * cos(deg * .pi / 180), y: center.y + ry * sin(deg * .pi / 180))
        }
        let nodes = devices.filter { $0.role == .node }
        var out: [(Device, CGPoint)] = []
        if let cloud = devices.first(where: { $0.role == .cloud }) { out.append((cloud, at(0))) }
        let left = Array(nodes.prefix(4))
        for (i, d) in left.enumerated() {
            let t = left.count == 1 ? 0.5 : Double(i) / Double(left.count - 1)
            out.append((d, at(left.count == 1 ? 180 : 125 + 110 * t)))
        }
        for (i, d) in nodes.dropFirst(4).enumerated() {
            // Alternate under and over this Mac, stepping right.
            let step = Double(i / 2) * 30
            out.append((d, at(i % 2 == 0 ? 90 - step : 270 + step)))
        }
        return out
    }

    private func linkLabel(_ d: Device) -> String {
        if d.id == serving, let r = servingRate ?? d.decode, r > 0 {
            return "\(d.link.label) · \(Int(r.rounded())) tok/s"
        }
        return d.link.label
    }
}

/// A straight link from the middle to a device, labelled at its midpoint. The serving link is
/// frog green, and flows while a turn streams.
private struct MapLink: View {
    let from: CGPoint
    let to: CGPoint
    let lit: Bool
    let live: Bool
    let online: Bool
    let label: String

    var body: some View {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        ZStack {
            TimelineView(.animation(paused: !live)) { tl in
                let phase = live ? -CGFloat(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 20) : 0
                Path { p in
                    p.move(to: from)
                    p.addLine(to: to)
                }
                .stroke(lit ? Tokens.accent : (online ? Tokens.textTertiary : Tokens.textQuaternary),
                        style: StrokeStyle(lineWidth: lit ? 2 : 1.25, lineCap: .round,
                                           dash: live ? [6, 4] : (online ? [] : [3, 4]), dashPhase: phase))
            }
            Text(label)
                .font(.frog(size: 10, weight: .medium))
                .foregroundStyle(lit ? Tokens.accent : Tokens.textSecondary)
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Tokens.raised))
                .position(mid)
        }
        .allowsHitTesting(false)
    }
}

/// One machine: what it is, how much memory it has free, what it's running and how fast.
struct DeviceCard: View {
    let device: Device
    let compact: Bool
    let serving: Bool
    @State private var pairing = false
    @State private var confirmUnpair = false

    private var needsPairing: Bool { device.role == .node && device.keyed && !device.paired }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if device.role == .thisMac {
                Text("This Mac")
                    .font(.frog(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 3 : 5)
                    .background(Tokens.hover)
            }
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 11 : 13))
                        .foregroundStyle(Tokens.textSecondary)
                    Text(device.name)
                        .font(.frog(size: compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if device.paired {
                        Menu {
                            Button("Un-pair \(device.name)…") { confirmUnpair = true }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Tokens.textTertiary)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    Circle().fill(dot).frame(width: 7, height: 7).help(status)
                }
                Text(spec)
                    .font(.frog(size: compact ? 10 : 11))
                    .foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1)
                if !compact { MemoryBar(device: device) }
                Spacer(minLength: 0)
                running
            }
            .padding(compact ? 9 : 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous).fill(Tokens.raised))
        .overlay {
            if serving {
                RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous)
                    .strokeBorder(Tokens.accent, lineWidth: 1.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 11 : 14, style: .continuous))
        .monospacedDigit()
        .contextMenu {
            if device.paired { Button("Un-pair \(device.name)…") { confirmUnpair = true } }
            if needsPairing { Button("Use \(device.name)…") { pairing = true } }
        }
        .sheet(isPresented: $pairing) { PairSheet(device: device) }
        .confirmationDialog("Un-pair \(device.name)?", isPresented: $confirmUnpair) {
            Button("Un-pair", role: .destructive) { Task { await Devices.shared.unpair(device.id) } }
        } message: {
            Text("This Mac forgets its key and \(device.name) drops this Mac. Pair again any time with a new code.")
        }
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
        case .cloud: return compact ? "for what won't fit" : "Hosted · \(device.chip)"
        default:
            guard device.totalBytes > 0 else { return device.chip }
            let mem: String
            if compact, let free = device.freeBytes {
                mem = "\(gb(free))/\(gb(device.totalBytes)) free"
            } else {
                mem = "\(gb(device.totalBytes)) \(device.unified ? "unified" : "VRAM")"
            }
            return [device.chip, mem].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    private var dot: Color {
        if device.refused != nil { return Tokens.fail }
        guard device.online, !needsPairing else { return Tokens.textQuaternary }
        return device.running + device.waiting > 0 ? Tokens.signal : Tokens.accent
    }

    private var status: String {
        if device.role == .cloud { return device.online ? "Signed in" : "Not signed in" }
        if let why = device.refused { return why }
        if needsPairing { return "Found on the network; not paired" }
        if !device.online { return device.role == .thisMac ? "Engine not running" : "Not answering" }
        if device.running > 0 { return "Working" + (device.waiting > 0 ? ", \(device.waiting) waiting" : "") }
        return "Ready"
    }

    @ViewBuilder private var running: some View {
        if device.role == .cloud {
            HStack(alignment: .firstTextBaseline) {
                Text(device.online ? "Ready" : "Sign in in Settings")
                    .foregroundStyle(device.online ? Tokens.text : Tokens.textTertiary)
                Spacer()
                if !compact {
                    Text("pay per token").font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
                }
            }
            .font(.frog(size: compact ? 11 : 12))
        } else if let why = device.refused {
            Text(why).font(.frog(size: compact ? 11 : 12)).foregroundStyle(Tokens.textSecondary).lineLimit(2)
        } else if needsPairing {
            HStack(alignment: .firstTextBaseline) {
                Text(device.pairOpen ? "Showing a code" : "Not paired")
                    .foregroundStyle(Tokens.textTertiary)
                Spacer()
                Button("Use it") { pairing = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text)
                    .fontWeight(.medium)
            }
            .font(.frog(size: compact ? 11 : 12))
        } else if let model = device.loading ?? device.model {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    if !compact || serving {
                        Text(serving ? "this turn" : (device.loading != nil ? "Loading" : "Loaded"))
                            .font(.frog(size: 10))
                            .foregroundStyle(serving ? Tokens.accent : Tokens.textTertiary)
                    }
                    Text(model)
                        .font(.frog(size: compact ? 11 : 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // A load in progress: how long so far (tang reports elapsed, not a fraction).
                    if device.loading != nil {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            if let s = device.loadingSecs, s >= 1 {
                                Text("\(Int(s)) s").font(.frog(size: 10)).foregroundStyle(Tokens.textTertiary)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                if !compact, let tps = device.decode {
                    Text(ModelStats.speedText(tps))
                        .font(.frog(size: 15, weight: .semibold))
                }
            }
        } else {
            Text(device.online ? "No model loaded" : status)
                .font(.frog(size: compact ? 11 : 12))
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

/// The chip's dot: frog green, breathing while a turn streams.
private struct BreathingDot: View {
    let live: Bool

    var body: some View {
        TimelineView(.animation(paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let pulse = live ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.4)) : 1
            Circle()
                .fill(Tokens.accent)
                .frame(width: 6, height: 6)
                .opacity(pulse)
        }
        .frame(width: 6, height: 6)
    }
}

private struct ProblemLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.frog(size: 12))
            .foregroundStyle(Tokens.signal)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Tokens.raised))
    }
}

/// The pool in one line: how many machines, how much memory, the fastest one right now.
private struct PoolSummary: View {
    let devices: [Device]

    static func up(_ devices: [Device]) -> [Device] {
        devices.filter { $0.role != .cloud && ($0.online || $0.role == .thisMac) }
    }

    static func line(_ devices: [Device]) -> String {
        let up = up(devices)
        let memory = up.reduce(UInt64(0)) { $0 + $1.totalBytes }
        return "\(up.count) \(up.count == 1 ? "machine" : "machines") · \(gb(memory)) pooled"
    }

    var body: some View {
        let up = Self.up(devices)
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
