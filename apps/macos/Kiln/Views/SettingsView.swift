import SwiftUI

/// ⌘, : General, Models, Permissions, Appearance, Shortcuts.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Models", systemImage: "cpu") { ModelSettings() }
            Tab("Permissions", systemImage: "hand.raised") { PermissionSettings() }
            Tab("Appearance", systemImage: "paintbrush") { AppearanceSettings() }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutSettings() }
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
                Text("kiln's default").tag("")
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
    /// Everything `kiln --models` knows, from the home folder.
    static func load() async -> [ModelEntry] {
        (try? await Kiln.json([ModelEntry].self, args: ["--models", "--json"],
                               cwd: FileManager.default.homeDirectoryForCurrentUser)) ?? []
    }
}

// MARK: - Models

private struct ModelSettings: View {
    @State private var models: [ModelEntry] = []
    @State private var loading = true

    private let sources: [(key: String, title: String)] = [
        ("tang", "Local: tang (open models on this Mac)"),
        ("apple", "Local: Apple Intelligence"),
        ("ollama", "Local: Ollama"),
        ("config", "Configured in config.toml"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(SuggestedModel.all) { m in
                    SuggestedModelRow(model: m) { Task { models = await Models.load() } }
                }
            } header: {
                Text("Get a local model")
            } footer: {
                Text("Downloads to the Hugging Face cache. Runs on kiln's own inference engine; no other software needed.")
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
        .frame(minHeight: 460)
        .task {
            models = await Models.load()
            loading = false
        }
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

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/kiln/config.toml")
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
                LabeledContent("Ask", value: "Every edit and command asks first")
                LabeledContent("Accept Edits", value: "File edits are allowed; commands still ask")
                LabeledContent("Yolo", value: "Everything runs without asking")
            }
            .foregroundStyle(.secondary)
            Section("Always-allowed commands") {
                Text("Command prefixes that never ask (like `cargo check`) live in kiln's config file, shared with the terminal app.")
                    .foregroundStyle(.secondary)
                Button("Open config.toml…") {
                    if !FileManager.default.fileExists(atPath: configURL.path) {
                        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? "# kiln configuration\n# allow_bash = [\"cargo check\", \"npm test\"]\n".write(to: configURL, atomically: true, encoding: .utf8)
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

    var body: some View {
        Form {
            Picker("Density", selection: $density) {
                ForEach(Density.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Show the model's thinking", isOn: $showThinking)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Conversation", [
            ("Send", "↩"), ("New line", "⇧↩"), ("Interrupt", "Esc  ·  ⌘."), ("Focus composer", "⌘L"),
            ("Mention a file", "@"), ("Run a shell command", "!cmd"),
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
