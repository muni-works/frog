import SwiftUI

/// Settings › Models: your machines (every node, This Mac included, gets the same row), a page
/// per machine, and Frog Cloud. Pairing lives here too.
struct MachinesSettings: View {
    @State var devices = Devices.shared
    /// Open on a machine's page (snapshots).
    var path: [String] = []
    /// A fixed account line and credit instead of the signed-in one (snapshots).
    var fixtureAccount: (line: String, credit: String)? = nil
    @State private var stack: [String] = []
    @State private var account = CloudAccount.shared
    @State private var pairing = false
    @AppStorage(ModelMenu.showCloudKey) private var showCloud = true
    @AppStorage("settingsTab") private var settingsTab = "general"

    var body: some View {
        NavigationStack(path: $stack) {
            Form {
                Section("Machines") {
                    ForEach(devices.machines) { d in
                        NavigationLink(value: d.id) { MachineRow(device: d) }
                    }
                    Button("Pair a machine…") { pairing = true }
                }
                if let problem = devices.browseProblem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Tokens.signal) }
                }
                Section(ProviderID.cloudName) {
                    LabeledContent("Account") { Text(accountLine) }
                    if let credit = fixtureAccount?.credit ?? account.me.map({ CloudFormat.dollars($0.credit_cents) }) {
                        LabeledContent("Credit") {
                            HStack {
                                Text(credit).monospacedDigit()
                                Button("Add credit…") { settingsTab = "billing" }
                            }
                        }
                    }
                    Toggle("Show cloud models in the picker", isOn: $showCloud)
                }
            }
            .formStyle(.grouped)
            .navigationDestination(for: String.self) { id in MachinePage(deviceID: id, devices: devices) }
        }
        .frame(minHeight: 480)
        .onAppear { if stack.isEmpty { stack = path } }
        .sheet(isPresented: $pairing) { PairMachineSheet() }
        .onAppear { devices.start() }
        .onDisappear { devices.stop() }
        .task {
            guard fixtureAccount == nil else { return }
            await account.ensureKey()
            await account.refresh()
        }
    }

    private var accountLine: String {
        if let f = fixtureAccount { return f.line }
        return account.me.map { [$0.name, $0.email].compactMap { $0 }.joined(separator: " · ") }
            ?? (account.signedIn ? "Signed in" : "Not signed in")
    }
}

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

/// A machine's page: status and memory, the models on its disk, and the node itself.
struct MachinePage: View {
    let deviceID: String
    @State var devices = Devices.shared
    @ObservedObject private var lender = MacLender.shared
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmUnpair = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    private var device: Device? { devices.list.first { $0.id == deviceID } }

    var body: some View {
        if let d = device {
            Form {
                Section {
                    LabeledContent("Status", value: d.statusLine)
                    LabeledContent("Hardware", value: d.hardwareLine)
                    if d.totalBytes > 0 { MachineMemoryBar(device: d) }
                }
                Section("Models") {
                    if d.models.isEmpty {
                        Text(d.online ? "No models on this machine." : "Not answering.").foregroundStyle(Tokens.textTertiary)
                    }
                    ForEach(d.models, id: \.weightsHash) { m in modelRow(d, m) }
                    if Devices.canPull {
                        Button("Download a model…") {}.disabled(true)
                    }
                    if let problem { Text(problem).font(.frog(size: 11)).foregroundStyle(Tokens.signal) }
                }
                Section("Node") {
                    if d.role == .thisMac {
                        Toggle("Share with my other machines", isOn: $lender.enabled)
                    } else {
                        Toggle("Share with my other machines", isOn: .constant(true))
                            .disabled(true)
                            .help("\(d.name) shares itself with every machine you pair it with.")
                    }
                    LabeledContent("Name") {
                        HStack {
                            Text(d.name)
                            Button("Rename…") { newName = d.name; renaming = true }
                        }
                    }
                    if d.role != .thisMac {
                        Button("Unpair \(d.name)…", role: .destructive) { confirmUnpair = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(d.name)
            .alert("Rename \(d.name)", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Rename") { devices.rename(d.id, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Unpair \(d.name)?", isPresented: $confirmUnpair) {
                Button("Unpair", role: .destructive) {
                    Task { await devices.unpair(d.id); dismiss() }
                }
            } message: {
                Text("This Mac forgets its key and \(d.name) drops this Mac. Pair again any time with a new code.")
            }
        } else {
            Text("This machine isn't paired anymore.").foregroundStyle(Tokens.textTertiary)
        }
    }

    private func modelRow(_ d: Device, _ m: Device.PooledModel) -> some View {
        let spec = "node/\(m.weightsHash.prefix(12))"
        let loading = devices.asked[spec] != nil || d.loadingID == m.id
        return HStack(spacing: 8) {
            Button {
                guard !m.loaded else { return }
                problem = nil
                Task {
                    do { try await devices.switchTo(spec, on: d.id) } catch { problem = error.localizedDescription }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: m.loaded ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(m.loaded ? Tokens.placeLocal : Tokens.textTertiary)
                    Text(Devices.displayName(m.name))
                    if let q = m.quant { Text(q).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary) }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
                Text(devices.waitingSwap[spec] != nil ? "swaps after this turn" : "loading")
                    .font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary)
            } else if m.loaded {
                if let tps = d.decode { Text(ModelStats.speedText(tps)).font(.frog(size: 11)).foregroundStyle(Tokens.textTertiary) }
                Button("Stop") {
                    Task { do { try await devices.stopModel(on: d.id) } catch { problem = error.localizedDescription } }
                }
            } else if Devices.canPull {
                Button("Delete") {}.disabled(true)
            }
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
            Text("Run `curl -fsSL https://frog.toys/node | sh` on a Linux GPU box on your network, or turn on Share with my other machines on another Mac, and it shows here.")
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
        return [chip, "\(Self.gb(totalBytes)) \(unified ? "unified" : "VRAM")"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Qwen3-8B · 58 tok/s", "idle", "offline".
    var runningLine: String {
        if let refused { return refused }
        if !online { return role == .thisMac ? "not running" : "offline" }
        if let loading { return "loading \(Devices.displayName(loading))" }
        guard let model else { return "idle" }
        return [Devices.displayName(model), decode.map(ModelStats.speedText)].compactMap { $0 }.joined(separator: " · ")
    }

    var statusLine: String {
        if let refused { return refused }
        if !online { return role == .thisMac ? "Engine not running" : "Not answering" }
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
