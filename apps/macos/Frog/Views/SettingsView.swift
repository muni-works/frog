import SwiftUI

/// ⌘, : General, Models, Permissions, Appearance, Shortcuts.
struct SettingsView: View {
    /// The open tab; "Manage models…" in the model picker sets it to "models".
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Models", systemImage: "cpu", value: "models") { ModelSettings() }
            Tab("Permissions", systemImage: "hand.raised", value: "permissions") { PermissionSettings() }
            Tab("MCP", systemImage: "puzzlepiece.extension", value: "mcp") { MCPSettings() }
            Tab("Appearance", systemImage: "paintbrush", value: "appearance") { AppearanceSettings() }
            Tab("Shortcuts", systemImage: "keyboard", value: "shortcuts") { ShortcutSettings() }
        }
        .frame(width: 620)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage("defaultModel") private var defaultModel = ""
    @AppStorage("editor") private var editor = ""
    @AppStorage("notifyWhenDone") private var notifyWhenDone = true
    @State private var models: [ModelEntry] = []

    var body: some View {
        Form {
            Picker("Default model", selection: $defaultModel) {
                Text("frog's default").tag("")
                ForEach(models) { m in Text(m.spec).tag(m.spec) }
            }
            .help("Used for new sessions. Change it for a session from the composer or the Model menu.")
            Picker("Open files in", selection: $editor) {
                Text(Editor.installed.first.map { "Automatic (\($0.name))" } ?? "Default app").tag("")
                ForEach(Editor.installed) { e in
                    Label {
                        Text(e.name)
                    } icon: {
                        if let icon = e.icon { Image(nsImage: icon) }
                    }
                    .tag(e.id)
                }
            }
            Toggle("Notify me when a turn finishes while I'm in another app", isOn: $notifyWhenDone)
        }
        .formStyle(.grouped)
        .task { models = await Models.load() }
    }
}

enum Models {
    /// Everything `frog --models` knows, from the home folder.
    static func load() async -> [ModelEntry] {
        (try? await Frog.json([ModelEntry].self, args: ["--models", "--json"],
                               cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
    }
}

// MARK: - Models

private struct ModelSettings: View {
    @State private var store = ProviderStore.shared
    @State private var models: [ModelEntry] = []
    @State private var loading = true
    @State private var keyFor: ProviderInfo?
    @State private var addingServer = false
    @State private var query = ""

    private let sources: [(key: String, title: String)] = [
        ("tang", "Local: tang (open models on this Mac)"),
        ("apple", "Local: Apple Intelligence"),
        ("ollama", "Local: Ollama"),
        ("server", "Your servers"),
        ("config", "Configured in config.toml"),
    ]

    /// Catalog matches for the search: every word must appear in the name or spec.
    private var matches: [CatalogModel] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return store.catalog.filter { $0.enabled == true } }
        return store.catalog.filter { m in
            let hay = (m.name + " " + m.spec).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(store.providers) { p in
                    ProviderRow(provider: p) { keyFor = p } remove: {
                        Task { await store.remove(p.id); models = await Models.load() }
                    }
                }
                Button("Add Server…") { addingServer = true }
            } header: {
                Text("Providers")
            } footer: {
                Text("Keys are kept in your Keychain. A server of your own, like a GPU box running Ollama, vLLM or llama.cpp, offers everything it serves.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Search \(store.catalog.count) models", text: $query)
                    .textFieldStyle(.roundedBorder)
                let list = Array(matches.prefix(150))
                if list.isEmpty {
                    Text(query.isEmpty ? "Search to find models from OpenRouter, Vercel AI Gateway and the providers you've connected, and turn on the ones you want in the picker." : "No models match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { m in
                    CatalogRow(model: m, provider: store.provider(m.provider)) { on in
                        Task { await store.setEnabled(m.spec, on) }
                    }
                }
                if matches.count > list.count {
                    Text("\(matches.count - list.count) more; narrow the search.").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(query.isEmpty ? "Models you've turned on" : "Models")
                    Spacer()
                    if store.loadingCatalog {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await store.loadCatalog(refresh: true) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Fetch the latest model lists")
                    }
                }
            }
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            Section {
                ForEach(SuggestedModel.all) { m in
                    SuggestedModelRow(model: m) { Task { models = await Models.load() } }
                }
            } header: {
                Text("Get a local model")
            } footer: {
                Text("Downloads to the Hugging Face cache. Runs on frog's own inference engine; no other software needed.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sources, id: \.key) { source in
                let rows = models.filter { $0.source == source.key }
                if !rows.isEmpty {
                    Section(source.title) {
                        ForEach(rows) { ModelRow(model: $0) }
                    }
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .sheet(item: $keyFor) { p in KeySheet(provider: p) }
        .sheet(isPresented: $addingServer) {
            ServerSheet { Task { models = await Models.load() } }
        }
        .task {
            await store.load()
            async let catalog: () = store.loadCatalog()
            models = await Models.load()
            loading = false
            await catalog
        }
        .onChange(of: store.generation) { Task { models = await Models.load() } }
    }
}

private struct ProviderRow: View {
    let provider: ProviderInfo
    let setKey: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(provider.connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if provider.custom {
                Button(provider.key == nil ? "Set Key…" : "Change Key…", action: setKey)
                    .help("For a server that asks for one, like vLLM started with --api-key")
                Button("Remove", role: .destructive, action: remove)
            } else if !provider.local, provider.key != "env" {
                Button(provider.connected ? "Change Key…" : "Add Key…", action: setKey)
            }
        }
    }

    private var status: String {
        if provider.custom { return provider.baseUrl }
        if provider.local { return "On this Mac, when it's running" }
        switch provider.key {
        case "env": return "Connected (key from the environment)"
        case "keychain": return "Connected"
        default: return "Not connected"
        }
    }
}

private struct CatalogRow: View {
    let model: CatalogModel
    let provider: ProviderInfo?
    let toggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { model.enabled ?? false }, set: toggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .disabled(!(provider?.connected ?? false) && model.enabled != true)
        .help(provider?.connected == false ? "Add a \(provider?.name ?? "provider") key to use this model" : model.spec)
    }

    private var details: String {
        var parts = [provider?.name ?? model.provider]
        if let c = model.contextLabel { parts.append("\(c) context") }
        if model.vision { parts.append("images") }
        if model.reasoning { parts.append("reasoning") }
        if !model.tools { parts.append("no tools") }
        if let p = model.price { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}

/// Paste a provider's API key; it goes to the Keychain through frog, never to disk.
private struct KeySheet: View {
    let provider: ProviderInfo
    @State private var key = ""
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(provider.name)").font(.headline)
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let url = URL(string: provider.keyUrl), !provider.keyUrl.isEmpty {
                Link("Get a key from \(provider.name)", destination: url).font(.callout)
            }
            Text("Stored in your Keychain. frog sends it only to \(provider.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let e = store.error { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                if provider.key == "keychain" {
                    Button("Remove Key", role: .destructive) {
                        Task { await store.setKey("", for: provider.id); dismiss() }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saving = true
        Task {
            await store.setKey(key, for: provider.id)
            saving = false
            if store.error == nil { dismiss() }
        }
    }
}

/// Add a server on your network (a GPU box running Ollama, vLLM, llama.cpp or LM Studio).
private struct ServerSheet: View {
    let added: () -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var ollama = true
    @State private var saving = false
    @State private var store = ProviderStore.shared
    @Environment(\.dismiss) private var dismiss

    /// "GPU Box" → "gpu-box".
    private var id: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return slug.split(separator: "-").joined(separator: "-")
    }

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("GPU Box"))
            Picker("Runs", selection: $ollama) {
                Text("Ollama").tag(true)
                Text("OpenAI-compatible (vLLM, llama.cpp, LM Studio)").tag(false)
            }
            TextField("URL", text: $url, prompt: Text(ollama ? "http://gpu-box.local:11434" : "http://gpu-box.local:8000/v1"))
            if !id.isEmpty {
                LabeledContent("Models appear as", value: "\(id)/<model>")
                    .foregroundStyle(.secondary)
            }
            if let e = store.error { Text(e).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") {
                    saving = true
                    Task {
                        let ok = await store.addServer(id: id, name: name, url: url.trimmingCharacters(in: .whitespaces), ollama: ollama)
                        saving = false
                        if ok { added(); dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(id.isEmpty || url.isEmpty || saving)
            }
            .padding()
        }
        .frame(width: 460, height: 300)
    }
}

private struct ModelRow: View {
    let model: ModelEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.spec.split(separator: "/", maxSplits: 1).last.map(String.init) ?? model.spec)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.tier.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let b = model.caps?.paramsB { parts.append(String(format: "%.1fB", b)) }
        parts.append("\(model.toolMode) tool calls")
        if model.caps == nil { parts.append("not profiled yet") }
        return parts.joined(separator: " · ")
    }
}

/// A recommended model with its download state: Download, a progress bar, or Installed.
struct SuggestedModelRow: View {
    let model: SuggestedModel
    var onInstalled: () -> Void = {}
    @State private var downloads = ModelDownloads.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).fontWeight(.medium)
                Text("\(model.detail) · \(String(format: "%.1f", model.approxGB)) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch downloads.states[model.repo] {
            case .downloading(let f):
                ProgressView(value: f).frame(width: 120)
                Text("\(Int(f * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Button { downloads.cancel(model.repo) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            case .failed(let e):
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(1)
                Button("Retry") { downloads.download(model.repo) }
            case .done:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case nil:
                if ModelDownloads.isInstalled(model.repo) {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Download") { downloads.download(model.repo) }
                }
            }
        }
        .onChange(of: downloads.states[model.repo]) { _, s in if s == .done { onInstalled() } }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @AppStorage("defaultMode") private var defaultMode = Mode.default.rawValue
    @AppStorage("computerUse") private var computerUse = false
    @AppStorage("sandboxShell") private var sandboxShell = true

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/config.toml")
    }

    var body: some View {
        Form {
            Picker("New sessions start in", selection: $defaultMode) {
                ForEach(Mode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            Section {
                LabeledContent("Ask", value: sandboxShell ? "Edits, and commands leaving the sandbox, ask first" : "Every edit and command asks first")
                LabeledContent("Accept Edits", value: "File edits are allowed; commands still ask")
                LabeledContent("Auto", value: "A local model approves steps that plainly serve your request; risky ones ask")
                LabeledContent("Yolo", value: "Everything runs without asking")
            }
            .foregroundStyle(.secondary)
            Section("Sandbox") {
                Toggle("Run shell commands in a sandbox", isOn: $sandboxShell)
                Text("Sandboxed commands can write only inside the project, temp folders and toolchain caches, and can't read credentials like ~/.ssh or ~/.aws, so they run without asking. A command that needs more asks first. Network access works either way. New sessions pick this up.")
                    .foregroundStyle(.secondary)
            }
            Section("Computer use") {
                Toggle("Let frog see and use other apps", isOn: $computerUse)
                Text("frog reads windows through Accessibility and acts on their buttons and fields, usually without taking over your screen. Every action asks first unless you allow it, and it never types into password fields. New sessions pick this up.")
                    .foregroundStyle(.secondary)
            }
            Section("Always-allowed commands") {
                Text("Command prefixes that never ask (like `cargo check`) live in frog's config file, shared with the terminal app.")
                    .foregroundStyle(.secondary)
                Button("Open config.toml…") {
                    if !FileManager.default.fileExists(atPath: configURL.path) {
                        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# frog configuration\n# allow_bash = [\"cargo check\", \"npm test\"]\n".write(to: configURL, atomically: true, encoding: .utf8)
                    }
                    Editor.open([configURL])
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

private struct AppearanceSettings: View {
    @AppStorage("density") private var density = Density.comfortable.rawValue
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("playfulFrog") private var playfulFrog = true
    @AppStorage("playfulSounds") private var playfulSounds = false

    var body: some View {
        Form {
            Picker("Density", selection: $density) {
                ForEach(Density.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Show the model's thinking", isOn: $showThinking)
            Section {
                Toggle("Playful frog", isOn: $playfulFrog)
                    .help("The frog blinks, reads and hops along with the conversation.")
                Toggle("Frog sounds", isOn: $playfulSounds)
                    .help("A quiet plip when you send, a ribbit when a turn finishes, a drip when it needs permission.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Conversation", [
            ("Send", "↩"), ("New line", "⇧↩"), ("Interrupt", "Esc  ·  ⌘."), ("Focus composer", "⌘L"),
            ("Dictate", "⌥⌘V"), ("Mention a file", "@"), ("Run a shell command", "!cmd"),
        ]),
        ("Navigate", [
            ("Previous / next turn", "⌥⌘↑  ⌥⌘↓"), ("Find in conversation", "⌘F"), ("Find next / previous", "⌘G  ⇧⌘G"),
            ("Command palette", "⌘K"),
        ]),
        ("Session", [
            ("New session", "⇧⌘N"), ("Race", "⌥⌘R"), ("Compact", "⇧⌘K"), ("Fork after last turn", "⇧⌘D"),
            ("Undo last turn", "⌥⌘Z"), ("Allow / deny a request", "⌘↩  ·  ⌘."),
        ]),
        ("Window", [
            ("Sessions", "⌃⌘S"), ("Changes", "⌥⌘0"), ("Permission mode", "⌃⌘1  ⌃⌘2  ⌃⌘3"), ("Open folder", "⌘O"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { item in
                        LabeledContent(item.0) {
                            Text(item.1).font(.body.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
    }
}

// MARK: - MCP

struct MCPStatus: Decodable, Identifiable {
    struct Quarantined: Decodable {
        let tool: String
        let reason: String
    }
    let name: String
    let connected: Bool
    let error: String?
    let tools: [String]
    let quarantined: [Quarantined]
    var id: String { name }
}

/// Servers from config.toml (every project) and how they're doing. Projects add their own
/// with a `.mcp.json` (Claude Code's format), which sessions in that folder pick up.
private struct MCPSettings: View {
    @State private var servers: [MCPStatus] = []
    @State private var loading = true

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/frog/config.toml")
    }

    var body: some View {
        Form {
            Section {
                if loading {
                    HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                } else if servers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(servers) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: s.connected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(s.connected ? .green : .red)
                            Text(s.name).fontWeight(.medium)
                            Spacer()
                            if s.connected {
                                Text("\(s.tools.count) tool\(s.tools.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            }
                        }
                        if let e = s.error {
                            Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
                        } else if !s.tools.isEmpty {
                            Text(s.tools.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        ForEach(s.quarantined, id: \.tool) { q in
                            Label("Withheld \(q.tool): its description \(q.reason)", systemImage: "exclamationmark.shield")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Servers in config.toml")
            } footer: {
                Text("Tools from MCP servers ask before running, like shell commands. Tools whose descriptions look like prompt injection are withheld unless the server has `trust = true`. A project can add servers with a `.mcp.json` file (the same format as Claude Code).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Open config.toml…") {
                    if !FileManager.default.fileExists(atPath: configURL.path) {
                        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# frog configuration\n".write(to: configURL, atomically: true, encoding: .utf8)
                    }
                    Editor.open([configURL])
                }
                Text(example)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button("Refresh") { Task { await load() } }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task { await load() }
    }

    private var example: String {
        """
        [mcp_servers.github]
        command = "npx"
        args = ["-y", "@modelcontextprotocol/server-github"]
        env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }

        [mcp_servers.docs]
        url = "https://example.com/mcp"
        """
    }

    private func load() async {
        loading = true
        servers = (try? await Frog.json([MCPStatus].self, args: ["--mcp", "--json"],
                                         cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
        loading = false
    }
}
