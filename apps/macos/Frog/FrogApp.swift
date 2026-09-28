import SwiftUI

@main
struct FrogApp: App {
    init() {
        LegacyKiln.migrate()
        // Keep frog's windows neutral gray: no wallpaper tint on window chrome, grouped settings
        // cards and materials (the per-app form of System Settings' "Allow wallpaper tinting").
        UserDefaults.standard.set(true, forKey: "AppleReduceDesktopTinting")
        Notifier.shared.setup()
    }

    var body: some Scene {
        WindowGroup("Frog", for: URL.self) { $folder in
            RootView(folder: $folder)
                .containerBackground(FrogCanvas.color, for: .window)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.presented)
        .commands { FrogCommands() }

        WindowGroup("Diagram", for: DiagramDocument.self) { $doc in
            if let doc {
                DiagramWindow(document: doc)
            }
        }
        .defaultSize(width: 960, height: 680)
        // Only ever opened from a diagram card, never at launch or by restoration.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .containerBackground(FrogCanvas.color, for: .window)
        }
    }
}

/// A window is one to three conversations side by side (panes), each in a project folder or (with
/// no folder) a plain chat. A new window starts as an empty chat; its composer's folder chip
/// points it at a folder before the first message. The first pane's folder is the window's
/// scene value, so relaunching reopens it.
struct RootView: View {
    @Binding var folder: URL?
    @State private var panes: Panes?

    var body: some View {
        Group {
            if let panes {
                WorkspaceView(panes: panes)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if folder == nil { folder = LaunchFolder.take() ?? Frog.chatFolder }
        }
        .onChange(of: folder, initial: true) { _, url in
            guard let url else { return }
            if let panes {
                // Panes report their own folder changes; only an outside change lands here.
                let first = panes.items[0]
                if first.workspace.folder.standardizedFileURL != url.standardizedFileURL {
                    panes.setWorkspace(Workspace(folder: url, fresh: true), in: first)
                }
            } else {
                let p = Panes(Workspace(folder: url))
                p.onPrimaryFolder = { folder = $0 }
                panes = p
                Recents.add(url)
            }
        }
        .onDisappear { panes?.stopAll() }
    }
}

/// `open Frog.app --args -FrogFolder <path>` opens that folder in the first window.
/// (AppKit reads `-Key value` launch arguments into UserDefaults; a bare path would be
/// treated as a document to open instead.)
@MainActor
enum LaunchFolder {
    private static var used = false

    static func take() -> URL? {
        guard !used else { return nil }
        used = true
        guard let path = UserDefaults.standard.string(forKey: "FrogFolder") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum Recents {
    private static let key = "recentFolders"

    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func add(_ url: URL) {
        guard !Frog.isChat(url) else { return }
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

/// First run, in the empty conversation: a choice between a model on this Mac (the one that
/// suits its memory) and the cloud. When the download finishes, an empty conversation switches
/// to it and says so. Once a model is on this Mac, this shrinks to a line, and goes away once
/// there are two. See docs/models.md, "First run".
struct LocalModelCard: View {
    let conversation: Conversation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.models) private var models
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("defaultModel") private var defaultModel = ""
    @State private var downloads = ModelDownloads.shared
    @State private var store = ProviderStore.shared
    @State private var keyFor: ProviderInfo?

    /// The model for this Mac: 8B with 16 GB or more, else 4B.
    private var recommended: SuggestedModel {
        let repo = ModelIdentity.memoryGB >= 16 ? "mlx-community/Qwen3-8B-4bit" : "mlx-community/Qwen3-4B-4bit"
        return SuggestedModel.all.first { $0.repo == repo } ?? SuggestedModel.all[0]
    }

    private var installed: [SuggestedModel] {
        SuggestedModel.all.filter { ModelDownloads.isInstalled($0.repo) || downloads.states[$0.repo] == .done }
    }

    /// Models ready on your devices, not counting Apple's.
    private var readyOnDevices: [ModelIdentity] {
        models.map(ModelIdentity.init).filter { !$0.place.isCloud && $0.place != .apple && $0.state.isReady }
    }

    var body: some View {
        Group {
            if installed.isEmpty {
                choice
            } else if readyOnDevices.count < 2, let first = installed.first {
                Button {
                    settingsTab = "models"
                    openSettings()
                } label: {
                    HStack(spacing: 4) {
                        ModelLabel(model: ModelIdentity(first), size: .caption)
                        Text("· Change").foregroundStyle(.tint)
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $keyFor) { p in KeySheet(provider: p) }
        .task { await store.load() }
        .onChange(of: downloads.states[recommended.repo]) { _, s in
            guard s == .done else { return }
            let m = recommended
            if defaultModel.isEmpty { defaultModel = m.spec }
            // Only a conversation that hasn't started moves over.
            if conversation.turns.isEmpty {
                conversation.setModel(m.spec)
                conversation.flash("\(m.title) is ready on this Mac and now your default.")
            }
        }
    }

    /// Side by side where there's room, stacked where there isn't.
    private var choice: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { mac; cloud }
            VStack(spacing: 12) { mac; cloud }
        }
        .frame(maxWidth: 600)
    }

    private var mac: some View {
        card {
            Label("On this Mac", systemImage: "laptopcomputer").font(.headline)
            Text("Private and free, and works offline. One download.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The card says what it's for; the row just names the model and its size.
            SuggestedModelRow(model: recommended, describe: false)
            Button("More models…") {
                settingsTab = "models"
                openSettings()
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private var cloud: some View {
        card {
            Label("Cloud", systemImage: "cloud").font(.headline)
            Text("The strongest models. Code you send goes to the provider, and each project asks first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Menu("Add a Key…") {
                ForEach(store.providers.filter { !$0.local && !$0.custom }) { p in
                    Button(p.name) { keyFor = p }
                }
            }
            .fixedSize()
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(minWidth: 230, maxWidth: 260, alignment: .leading)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// frog was called kiln. Before anything touches frog's folders or settings, move kiln's over:
/// config and data (the old paths become symlinks, so paths in old sessions still resolve) and
/// the app's preferences (pins, archive, settings) from kiln's bundle id.
enum LegacyKiln {
    static func migrate() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for (old, new) in [(".config/kiln", ".config/frog"), (".local/share/kiln", ".local/share/frog")] {
            let from = home.appending(path: old), to = home.appending(path: new)
            let isRealDir = (try? from.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]))
                .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
            guard isRealDir, !fm.fileExists(atPath: to.path) else { continue }
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: from, to: to)) != nil {
                try? fm.createSymbolicLink(at: from, withDestinationURL: to)
            }
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedKilnDefaults") else { return }
        let oldID = "com.campedersen.kiln" as CFString
        let keys = CFPreferencesCopyKeyList(oldID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = CFPreferencesCopyAppValue(key as CFString, oldID) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "importedKilnDefaults")
    }
}
