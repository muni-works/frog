import AppKit
import SwiftUI

/// The Mac's side of design/settings.json: each row's control and where it's kept. The words
/// come from the list; a test holds this switch to it (every Mac row has a control, and nothing
/// here is for a row the list doesn't give the Mac).
enum SettingsBindings {
    /// Rows drawn inside another row's block, not on their own.
    static let drawnBy: [String: String] = [
        "mcp-sign-in": "mcp-servers",
        // A machine's models are on its page, which the machines list opens.
        "local-models": "machines",
        // A provider's models open from its row (Models).
        "provider-models": "other-clouds",
        // The chart is this Mac's measured energy.
        "measured-energy": "energy-chart",
        // The code field is in the credit card, as on the web.
        "coupon": "credit",
    ]

    /// Rows that draw their own group label, since they may have nothing to show (other clouds
    /// and servers, while adding them is hidden and none are connected).
    static let ownLabel: Set<String> = ["other-clouds", "servers"]
    /// Rows that lay themselves out (their own hairlines, or Billing's cards).
    static let ownLayout: Set<String> = ownLabel.union(["plan", "credit", "credit-history", "prices"])

    /// The machines Models lists, and the spend and energy Usage shows (snapshots bring their own).
    @MainActor static var devices = Devices.shared
    @MainActor static var stats = ModelStats.shared
    /// Off in snapshots: no row starts the engine, probes a server or calls the edge while it
    /// renders (one did, and hung a full test run).
    @MainActor static var loads = true

    /// A row's control, or nil if the Mac has none for it.
    @MainActor
    static func control(for row: SettingsCatalog.Row) -> AnyView? {
        switch row.id {
        // General
        case "notifications": AnyView(ToggleRow(row: row, key: "notifyWhenDone", fallback: true))
        case "editor": AnyView(EditorRow(row: row))
        case "iphone": AnyView(IPhoneRow(row: row))
        case "share-usage": AnyView(ShareUsageRow(row: row))
        case "update-pause": AnyView(ToggleRow(row: row, key: UpdateDrain.key, fallback: false))
        case "update-wait": AnyView(UpdateWaitRow(row: row))
        // Appearance
        case "theme": AnyView(ChoiceRow(row: row, key: AppTheme.key, fallback: "system") { AppTheme.apply($0) })
        case "density": AnyView(ChoiceRow(row: row, key: "density", fallback: Density.comfortable.rawValue))
        case "detail": AnyView(DetailRow(row: row))
        case "playful": AnyView(ToggleRow(row: row, key: "playfulFrog", fallback: true))
        case "sounds": AnyView(ToggleRow(row: row, key: "playfulSounds", fallback: false))
        // Permissions
        case "default-mode": AnyView(ModeRow(row: row))
        case "sandbox": AnyView(ToggleRow(row: row, key: "sandboxShell", fallback: true))
        case "computer-use": AnyView(ToggleRow(row: row, key: "computerUse", fallback: false))
        case "allowed-commands": AnyView(SettingsRow(row) { OpenConfigButton() })
        // Connections
        case "mcp-servers": AnyView(MCPServersRows(row: row))
        case "mcp-config": AnyView(SettingsRow(row) { OpenConfigButton() })
        // Shortcuts
        case "shortcuts": AnyView(ShortcutRows())
        // Models
        case "default-model": AnyView(DefaultModelRow(row: row))
        case "machines": AnyView(MachinesRows())
        case "pair-machine": AnyView(PairMachineRow(row: row))
        case "frog-cloud": AnyView(FrogCloudRows())
        case "other-clouds": AnyView(OtherCloudsRows(row: row))
        case "servers": AnyView(ServersRows(row: row))
        case "machine-name": AnyView(MachineNameRow(row: row))
        case "share-models": AnyView(ShareRow(row: row))
        case "lend-battery": AnyView(LendBatteryRow(row: row))
        case "pair-mac": AnyView(PairMacRow(row: row))
        // Usage
        case "spent": AnyView(SpentRow(row: row))
        case "monthly-cap": AnyView(CapRow(row: row))
        case "show-energy": AnyView(ToggleRow(row: row, key: ModelStats.energyKey, fallback: false))
        case "energy-chart": AnyView(EnergyRows(stats: stats))
        // Account
        case "profile": AnyView(ProfileRows())
        case "sign-ins": AnyView(SignInsRows())
        case "devices": AnyView(DevicesRows())
        // Billing
        case "plan": AnyView(PlanBlock())
        case "credit": AnyView(CreditBlock())
        case "credit-history": AnyView(CreditHistoryRows())
        case "prices": AnyView(PricesRows(row: row))
        default: nil
        }
    }

    @MainActor
    static func view(for row: SettingsCatalog.Row) -> AnyView {
        control(for: row) ?? AnyView(EmptyView())
    }
}

// MARK: - Generic rows

/// A switch kept in UserDefaults.
private struct ToggleRow: View {
    let row: SettingsCatalog.Row
    @AppStorage private var on: Bool

    init(row: SettingsCatalog.Row, key: String, fallback: Bool) {
        self.row = row
        _on = AppStorage(wrappedValue: fallback, key)
    }

    var body: some View {
        SettingsRow(row) { FrogToggle(label: row.label, isOn: $on) }
    }
}

/// A segmented choice kept in UserDefaults, with the list's options.
private struct ChoiceRow: View {
    let row: SettingsCatalog.Row
    var onChange: (String) -> Void = { _ in }
    @AppStorage private var value: String

    init(row: SettingsCatalog.Row, key: String, fallback: String, onChange: @escaping (String) -> Void = { _ in }) {
        self.row = row
        self.onChange = onChange
        _value = AppStorage(wrappedValue: fallback, key)
    }

    var body: some View {
        SettingsRow(row) {
            FrogSegmented(label: row.label, options: row.options ?? [], selection: Binding(get: { value }, set: { value = $0; onChange($0) }))
        }
    }
}

/// Opens Frog's config file, making it first if there isn't one.
struct OpenConfigButton: View {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/config.toml") }

    var body: some View {
        Button("Open config.toml") {
            let url = Self.url
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "# frog configuration\n# allow_bash = [\"cargo check\", \"npm test\"]\n".write(to: url, atomically: true, encoding: .utf8)
            }
            Editor.open([url])
        }
        .buttonStyle(SettingsButtonStyle())
        .help("~/.config/frog/config.toml, in your editor")
    }
}

// MARK: - General

private struct EditorRow: View {
    let row: SettingsCatalog.Row
    @AppStorage("editor") private var editor = ""

    private var title: String {
        if let e = Editor.installed.first(where: { $0.id == editor }) { return e.name }
        return Editor.installed.first.map { "Automatic (\($0.name))" } ?? "Default app"
    }

    var body: some View {
        SettingsRow(row) {
            FrogPillMenu(title: title, help: "The app that opens files Frog changed") {
                Button(Editor.installed.first.map { "Automatic (\($0.name))" } ?? "Default app") { editor = "" }
                ForEach(Editor.installed) { e in Button(e.name) { editor = e.id } }
            }
        }
    }
}

/// The switch, and while it's on, the code to scan and the push relay secret.
private struct IPhoneRow: View {
    let row: SettingsCatalog.Row
    @AppStorage("remoteEnabled") private var remote = false
    @AppStorage(RemotePush.secretKey) private var pushSecret = ""
    @State private var code = RemoteBridge.token

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(row) {
                FrogToggle(label: row.label, isOn: Binding(get: { remote }, set: { on in
                    remote = on
                    on ? RemoteBridge.shared.start() : RemoteBridge.shared.stop()
                }))
            }
            if remote {
                PairingCard(code: code) {
                    RemoteBridge.newToken()
                    RemoteBridge.shared.stop()
                    RemoteBridge.shared.start()
                    code = RemoteBridge.token
                }
                .padding(.bottom, 8)
                SettingsRow("Push relay secret", description: "Lets this Mac wake your phone through frog.toys when Frog needs you.") {
                    SecureField("Secret", text: $pushSecret)
                        .textFieldStyle(.plain)
                        .font(.frog(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Tokens.raised, in: .rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.lineStrong))
                        .frame(width: 180)
                }
            }
        }
    }
}

/// Opt-in funnel events; turning it off forgets what was queued.
private struct ShareUsageRow: View {
    let row: SettingsCatalog.Row
    @AppStorage(Funnel.optInKey) private var on = false

    var body: some View {
        SettingsRow(row) {
            FrogToggle(label: row.label, isOn: Binding(get: { on }, set: { on = $0; if !$0 { Funnel.forget() } }))
        }
    }
}

/// Seconds to wait for agents before an update installs; shown while pausing is on.
private struct UpdateWaitRow: View {
    let row: SettingsCatalog.Row
    @AppStorage(UpdateDrain.key) private var pausing = false
    @AppStorage(UpdateDrain.budgetKey) private var budget = 20.0
    @State private var text = ""

    var body: some View {
        if pausing {
            SettingsRow(row) {
                FrogField(label: row.label, text: $text, width: 70) {
                    if let s = Double(text.trimmingCharacters(in: .whitespaces)) { budget = min(120, max(5, s.rounded())) }
                    text = String(Int(budget))
                }
            }
            .onAppear { text = String(Int(budget)) }
        }
    }
}

/// The QR code a phone scans to pair (a `frog://pair` link the Camera app opens in frog), and the
/// code itself for typing.
struct PairingCard: View {
    let code: String
    let renew: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let qr = Self.qr(RemoteBridge.pairingURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(8)
                    .background(.white, in: .rect(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(RemoteBridge.name).font(.frog(size: 13, weight: .semibold))
                Text(code).font(.frog(size: 13).monospaced()).textSelection(.enabled)
                Button("New code", action: renew).buttonStyle(SettingsButtonStyle())
                    .help("Every phone using the old code is signed out")
            }
        }
        .padding(.vertical, 4)
        .id(code)
    }

    static func qr(_ url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Appearance

/// Detail: the app's default level; the selected level's line is the description.
private struct DetailRow: View {
    let row: SettingsCatalog.Row
    @AppStorage(Verbosity.key) private var verbosity = Verbosity.standard.rawValue

    var body: some View {
        let picked = row.options?.first { $0.id == verbosity }
        SettingsRow(row, description: picked?.description) {
            FrogSegmented(label: row.label, options: row.options ?? [], selection: $verbosity)
        }
    }
}

// MARK: - Permissions

/// New sessions start in: the selected mode's one line under the label.
private struct ModeRow: View {
    let row: SettingsCatalog.Row
    @AppStorage("defaultMode") private var mode = Mode.auto.rawValue
    @AppStorage("sandboxShell") private var sandbox = true

    var body: some View {
        let picked = row.options?.first { $0.id == mode }
        // Without the sandbox, Ask asks for every command, not only those leaving it.
        let line = mode == Mode.default.rawValue && !sandbox ? "Every edit and command asks first." : picked?.description
        SettingsRow(row, description: line) {
            FrogSegmented(label: row.label, options: row.options ?? [], selection: $mode)
        }
    }
}

// MARK: - Connections

/// The servers in config.toml (and projects' .mcp.json) and how each is doing; one that wants a
/// sign-in has the button for it.
private struct MCPServersRows: View {
    let row: SettingsCatalog.Row
    @State private var servers: [MCPStatus] = []
    @State private var loading = true
    @State private var signingIn: Set<String> = []

    var body: some View {
        Group {
            SettingsRow(row) {
                Button("Refresh") { Task { await load() } }.buttonStyle(SettingsButtonStyle())
                    .help("Ask each server again")
            }
            if loading {
                SettingsRow("Connecting…") { ProgressView().controlSize(.small) }
            } else if servers.isEmpty {
                SettingsRow("No servers yet") { EmptyView() }
            }
            ForEach(servers) { s in
                SettingsRow(s.name, description: detail(s)) { state(s) }
            }
        }
        .task { guard SettingsBindings.loads else { return }; await load() }
    }

    private func detail(_ s: MCPStatus) -> String? {
        var parts: [String] = []
        if let e = s.error, s.needsAuth != true { parts.append(e) } else if !s.tools.isEmpty { parts.append(s.tools.joined(separator: " · ")) }
        parts += s.quarantined.map { "Withheld \($0.tool): its description \($0.reason)" }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func state(_ s: MCPStatus) -> some View {
        if s.connected {
            SettingsValue("\(s.tools.count) tool\(s.tools.count == 1 ? "" : "s")", help: "Connected")
        } else if s.needsAuth == true {
            if signingIn.contains(s.name) {
                ProgressView().controlSize(.small)
            } else {
                Button("Sign in") { signIn(s) }.buttonStyle(SettingsButtonStyle())
                    .help(s.declined == true ? "Opens \(s.name)'s sign-in in your browser (you declined before)" : "Opens \(s.name)'s sign-in in your browser")
            }
        } else {
            SettingsValue("Not connected")
        }
    }

    private func load() async {
        loading = true
        servers = (try? await Frog.json([MCPStatus].self, args: ["--mcp", "--json"],
                                         cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
        loading = false
    }

    /// The only thing in frog that opens a browser for MCP: a one-shot `frog --mcp-signin`, then
    /// the list reloads either way, the server's own state being the truth.
    private func signIn(_ s: MCPStatus) {
        guard !signingIn.contains(s.name) else { return }
        signingIn.insert(s.name)
        Task {
            try? await Frog.run(args: ["--mcp-signin", s.name], cwd: FileManager.default.homeDirectoryForCurrentUser)
            await load()
            signingIn.remove(s.name)
        }
    }
}

// MARK: - Shortcuts

/// The Mac app's keys, read-only, by group.
struct ShortcutRows: View {
    static let groups: [(String, [(String, String)])] = [
        ("Conversation", [
            ("Send", "↩"), ("New line", "⇧↩"), ("Interrupt", "Esc  ·  ⌘."), ("Focus composer", "⌘L"),
            ("Dictate", "⌥⌘V"), ("Mention a file", "@"), ("Run a shell command", "!cmd"),
        ]),
        ("Navigate", [
            ("Previous / next turn", "⌥⌘↑  ⌥⌘↓"), ("Find in conversation", "⌘F"), ("Find next / previous", "⌘G  ⇧⌘G"),
            ("Command palette", "⌘K"), ("Settings", "⌘,"),
        ]),
        ("Session", [
            ("New session", "⇧⌘N"), ("Race", "⌥⌘R"), ("Compact", "⇧⌘K"), ("Fork after last turn", "⇧⌘D"),
            ("Undo last turn", "⌥⌘Z"), ("Allow / deny a request", "⌘↩  ·  ⌘."),
        ]),
        ("Window", [
            ("Sessions", "⌃⌘S"), ("Changes", "⌥⌘0"), ("Terminal", "⇧⌘T"), ("Preview", "⇧⌘P"),
            ("Inspect an element in the preview", "⇧⌘I"), ("Permission mode", "⌃⌘1  ⌃⌘2  ⌃⌘3"), ("Open folder", "⌘O"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.groups, id: \.0) { group in
                SettingsGroupLabel(text: group.0)
                SettingsRows(divided: false) {
                    ForEach(group.1, id: \.0) { item in
                        SettingsRow(item.0) {
                            Text(item.1).font(.frog(size: 12).monospaced()).foregroundStyle(Tokens.textSecondary)
                        }
                    }
                }
            }
        }
    }
}
