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

/// A window is one conversation, in a project folder or (with no folder) a plain chat. A new
/// window or tab starts as an empty chat; its composer's folder chip points it at a folder
/// before the first message.
struct RootView: View {
    @Binding var folder: URL?
    @State private var workspace: Workspace?
    /// Start a new conversation rather than reopening the folder's last one.
    @State private var fresh = false
    /// A session to open when the folder changes (picked in the sidebar).
    @State private var resume: String?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.switchFolder) { url in
            fresh = true
            folder = url ?? Frog.chatFolder
        }
        .environment(\.openSession) { s in
            guard let url = s.folder, workspace?.conversation?.sessionID != s.id else { return }
            if let w = Library.shared.window(for: s.id) {
                w.makeKeyAndOrderFront(nil)
            } else if let workspace, workspace.folder.standardizedFileURL.path == url.standardizedFileURL.path {
                workspace.open(s.id)
            } else {
                resume = s.id
                folder = url
            }
        }
        .onAppear {
            if folder == nil { folder = LaunchFolder.take() ?? Frog.chatFolder }
        }
        .onChange(of: folder, initial: true) { _, url in
            workspace?.stop()
            workspace = url.map { Workspace(folder: $0, fresh: fresh, resume: resume) }
            resume = nil
            if let url { Recents.add(url) }
        }
        .onDisappear { workspace?.stop() }
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

/// First run: if no open model is on this Mac yet, offer the recommended one right in the empty
/// conversation. Once one is installed this shrinks to a line pointing at Settings.
struct LocalModelCard: View {
    @Environment(\.openSettings) private var openSettings
    @State private var downloads = ModelDownloads.shared

    private var installed: [SuggestedModel] {
        SuggestedModel.all.filter { ModelDownloads.isInstalled($0.repo) || downloads.states[$0.repo] == .done }
    }

    var body: some View {
        if installed.isEmpty, let first = SuggestedModel.all.first {
            VStack(alignment: .leading, spacing: 10) {
                Label("Run a model on this Mac", systemImage: "cpu").font(.headline)
                Text("frog has its own inference engine. Download a model once and work fully offline.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SuggestedModelRow(model: first)
                Button("More models…") { openSettings() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .frame(width: 420)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else if !installed.isEmpty {
            Button {
                openSettings()
            } label: {
                Label("\(installed.map(\.title).joined(separator: ", ")) ready on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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
