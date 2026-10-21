import SwiftUI

@main
struct FrogApp: App {
    init() {
        if MorningNotice.headless {
            // Woken by the brief's watcher to post the morning notice: no window, no Dock icon,
            // and never in the way of a frog that's already open (it asks on its own).
            if SingleInstance.otherIsRunning { exit(0) }
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            // One frog: a second copy hands its folder to the running one and quits.
            SingleInstance.handOff()
        }
        if SingleInstance.isTesting {
            // A test host: no Dock icon, no windows of its own (tests render offscreen).
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        LegacyKiln.migrate()
        // Keep frog's windows neutral gray: no wallpaper tint on window chrome, grouped settings
        // cards and materials (the per-app form of System Settings' "Allow wallpaper tinting").
        UserDefaults.standard.set(true, forKey: "AppleReduceDesktopTinting")
        Notifier.shared.setup()
        Conversation.effects = MacEffects.shared
        SessionBroker.shared.install()
        ModelContext.useMac()
        DiagramLayout.mermaid = { source, cwd in
            await Diagram.fromMermaid(source, cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        MorningNotice.start()
        _ = Updates.shared
        RemoteBridge.shared.startIfEnabled()
    }

    var body: some Scene {
        WindowGroup("Frog", for: URL.self) { $folder in
            RootView(folder: $folder)
                .containerBackground(FrogCanvas.color, for: .window)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(SingleInstance.isTesting || MorningNotice.headless ? .suppressed : .presented)
        .restorationBehavior(SingleInstance.isTesting || MorningNotice.headless ? .disabled : .automatic)
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
    @Environment(\.openWindow) private var openWindow
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
        // Drag the window from any empty space, not just the title bar. Text selection,
        // buttons and fields are children, so their own gestures win.
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
        .onAppear {
            if folder == nil { folder = LaunchFolder.take() ?? Frog.chatFolder }
        }
        // A second copy of frog handed over its folder: open it here, in a window of its own.
        .onReceive(DistributedNotificationCenter.default().publisher(for: SingleInstance.openFolder)) { note in
            guard let token = note.object as? String, SingleInstance.answered.insert(token).inserted,
                  let path = token.split(separator: "|", maxSplits: 1).last.map(String.init) else { return }
            openWindow(value: URL(fileURLWithPath: path))
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

/// There's one frog, with many windows. Launching another copy (a second build, or `open -n`)
/// passes its `-FrogFolder` to the one that's running, brings that forward, and quits. Test
/// hosts (XCTest launches the app to run its tests) are left alone and kept out of sight.
enum SingleInstance {
    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Per bundle id, so a debug frog and the installed one don't open each other's folders.
    static let openFolder = Notification.Name("\(Bundle.main.bundleIdentifier ?? "eco.frog").openFolder")

    /// Another copy of this frog is running.
    static var otherIsRunning: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    static func handOff() {
        guard !isTesting, let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated })
        else { return }
        if let path = UserDefaults.standard.string(forKey: "FrogFolder") {
            // A token, so only one of the running copy's windows answers it.
            DistributedNotificationCenter.default().postNotificationName(
                openFolder, object: "\(UUID().uuidString)|\(path)", deliverImmediately: true)
        }
        running.activate()
        exit(0)
    }

    /// Tokens already answered, across the running copy's windows.
    @MainActor static var answered: Set<String> = []
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

extension SuggestedModel {
    /// The model for this Mac: 32B at 48 GB, 8B at 16 GB, else 4B.
    static var forThisMac: SuggestedModel {
        let repo: String
        switch ModelIdentity.memoryGB {
        case 48...: repo = "mlx-community/Qwen3-32B-4bit"
        case 16...: repo = "mlx-community/Qwen3-8B-4bit"
        default: repo = "mlx-community/Qwen3-4B-4bit"
        }
        return all.first { $0.repo == repo } ?? all[0]
    }
}

/// One quiet line in an empty conversation, while there's no model on this Mac yet: "Using
/// Apple Intelligence. Get Qwen3 32B for bigger tasks · 18 GB". Get downloads the model that
/// suits this Mac and switches to it when it's ready, like picking it in the picker. Gone once
/// there's a model on this Mac or a cloud key, or once it's closed.
struct ModelSuggestion: View {
    let conversation: Conversation
    @AppStorage("modelSuggestionClosed") private var closed = false
    @State private var downloads = ModelDownloads.shared
    @State private var store = ProviderStore.shared

    private var recommended: SuggestedModel { .forThisMac }

    private var hasLocal: Bool {
        SuggestedModel.all.contains { ModelDownloads.isInstalled($0.repo) || downloads.states[$0.repo] == .done }
    }

    private var hasCloud: Bool { store.providers.contains { !$0.local && $0.connected } }

    private var onApple: Bool { conversation.status?.model == AppleIntelligence.spec }

    var body: some View {
        let m = ModelIdentity(recommended)
        Group {
            if !closed, !hasLocal, !hasCloud {
                HStack(spacing: 4) {
                    switch m.state {
                    case .downloading(let f):
                        ProgressView(value: f)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text("Downloading \(m.name) · \(m.stateLine ?? "")")
                        Button("Stop") { downloads.cancel(recommended.repo) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                    default:
                        if onApple { Text("Using Apple Intelligence.") }
                        Button("Get \(m.name)") { downloads.download(recommended.repo) }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint)
                        Text("for bigger tasks · \(String(format: "%.1f GB", recommended.approxGB))")
                    }
                    Button {
                        closed = true
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .help("Don't suggest this again")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .task { await store.load() }
        .onChange(of: downloads.states[recommended.repo]) { _, s in
            guard s == .done else { return }
            // Like picking it: remembered for new conversations, and this one moves over if it
            // hasn't started.
            UserDefaults.standard.set(recommended.spec, forKey: "lastModel")
            if conversation.turns.isEmpty {
                conversation.setModel(recommended.spec)
                conversation.flash("\(recommended.title) is ready on this Mac.")
            }
        }
    }
}

/// frog was called kiln. Before anything touches frog's folders or settings, move kiln's over:
/// config and data (the old paths become symlinks, so paths in old sessions still resolve) and
/// the app's preferences (pins, archive, settings) from frog's and kiln's old bundle ids.
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
        // Then the preferences, newest bundle id first: frog was com.campedersen.frog before
        // eco.frog, and com.campedersen.kiln before that.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "importedLegacyDefaults") else { return }
        for oldID in ["com.campedersen.frog", "com.campedersen.kiln"] {
            let id = oldID as CFString
            let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = CFPreferencesCopyAppValue(key as CFString, id) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: "importedLegacyDefaults")
    }
}
