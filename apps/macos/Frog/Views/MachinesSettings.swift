import SwiftUI

/// One machine: what it is, and what it's running (with tok/s) or "idle".
struct MachineRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.machineSymbol)
                .foregroundStyle(Tokens.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.frog(size: 13, weight: .medium))
                    if device.role == .thisMac {
                        Text("This Mac").font(.frog(size: 10)).foregroundStyle(Tokens.textTertiary)
                    }
                }
                Text(device.hardwareLine).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(device.runningLine)
                .font(.frog(size: 12))
                .foregroundStyle(device.model != nil ? Tokens.text : Tokens.textTertiary)
                .lineLimit(1)
            Circle().fill(Tokens.placeLocal.opacity(device.online ? 1 : 0.25)).frame(width: 7, height: 7)
        }
        .monospacedDigit()
    }
}

/// How much of a machine's memory is spoken for.
struct MachineMemoryBar: View {
    let device: Device

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.hover)
                    Capsule().fill(Tokens.placeLocal)
                        .frame(width: geo.size.width * (device.usedFraction ?? 0))
                }
            }
            .frame(height: 6)
            Text(device.memoryLine).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
        }
        .monospacedDigit()
        .animation(.smooth(duration: 0.4), value: device.usedFraction)
    }
}

/// Pair a machine: the nodes on your network you haven't paired, and how to add one.
struct PairMachineSheet: View {
    @State private var devices = Devices.shared
    @State private var pairing: Device?
    @Environment(\.dismiss) private var dismiss

    private var unpaired: [Device] { devices.list.filter { $0.role == .node && !$0.paired } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a machine").font(.frog(size: 15, weight: .semibold))
            if unpaired.isEmpty {
                Text("No machines found on your network yet.").foregroundStyle(Tokens.textSecondary)
            }
            ForEach(unpaired) { d in
                HStack {
                    Image(systemName: d.machineSymbol).foregroundStyle(Tokens.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name)
                        Text(d.hardwareLine).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
                    }
                    Spacer()
                    Button("Pair…") { pairing = d }.disabled(!d.keyed)
                }
            }
            Text("Run `curl -fsSL https://frog.toys/node | sh` on a Linux GPU box on your network, or turn on “Share with my other machines” in Settings › Models on another Mac. It shows up here.")
                .font(.frog(size: 12))
                .foregroundStyle(Tokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheet(item: $pairing) { d in PairSheet(device: d) }
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
    }
}

@MainActor
extension Device {
    var machineSymbol: String {
        switch role {
        case .thisMac: symbol
        case .cloud: "cloud"
        case .node: kind == "metal" ? "desktopcomputer" : "server.rack"
        }
    }

    /// "RTX 3090 · 24 GB VRAM".
    var hardwareLine: String {
        guard totalBytes > 0 else { return chip }
        return [chip, "\(Self.gb(totalBytes)) \(unified ? "unified" : "VRAM")"].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// "Qwen3-8B · 58 tok/s", "idle", "offline".
    var runningLine: String {
        if let refused { return refused }
        if !online { return role == .thisMac ? "not running" : "offline" }
        if let loading { return "loading \(LocalCatalog.displayName(loading))" }
        if let stuckLoad { return "stuck loading \(LocalCatalog.displayName(stuckLoad.id))" }
        guard let model else { return "idle" }
        return [LocalCatalog.displayName(model), decode.map(ModelStats.speedText)].compactMap { $0 }.joined(separator: ", ")
    }

    var statusLine: String {
        if let refused { return refused }
        if !online { return role == .thisMac ? "Engine not running" : "Not answering" }
        if let stuckLoad { return "Stuck loading \(LocalCatalog.displayName(stuckLoad.id))" }
        if running > 0 { return "Working" + (waiting > 0 ? ", \(waiting) waiting" : "") }
        return model == nil ? "Idle" : "Ready"
    }

    /// "18 GB of 24 GB used".
    var memoryLine: String {
        guard let free = freeBytes else { return Self.gb(totalBytes) }
        return "\(Self.gb(totalBytes - min(free, totalBytes))) of \(Self.gb(totalBytes)) used"
    }

    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        return g >= 10 ? "\(Int(g.rounded())) GB" : String(format: "%.1f GB", g)
    }
}
