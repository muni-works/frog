import SwiftUI

@main
struct KilnApp: App {
    init() {
        Notifier.shared.setup()
    }

    var body: some Scene {
        WindowGroup("Kiln", for: URL.self) { $folder in
            RootView(folder: $folder)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.presented)
        .commands { KilnCommands() }

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
        }
    }
}

/// A window is one project folder. A new window or tab starts with the composer and a folder
/// chip (nothing is assumed); the conversation starts once a folder is picked.
struct RootView: View {
    @Binding var folder: URL?
    @State private var workspace: Workspace?
    /// The first message, typed before the folder was picked.
    @State private var pending: String?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else {
                StartView { url, prompt in
                    pending = prompt
                    folder = url ?? Kiln.chatFolder
                }
                .navigationTitle("New Conversation")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if folder == nil, let launched = LaunchFolder.take() { folder = launched }
        }
        .onChange(of: folder, initial: true) { _, url in
            workspace?.stop()
            workspace = url.map { Workspace(folder: $0, fresh: pending != nil) }
            if let url { Recents.add(url) }
            if let prompt = pending {
                workspace?.conversation?.submit(prompt)
                pending = nil
            }
        }
        .onDisappear { workspace?.stop() }
    }
}

/// `open Kiln.app --args -KilnFolder <path>` opens that folder in the first window.
/// (AppKit reads `-Key value` launch arguments into UserDefaults; a bare path would be
/// treated as a document to open instead.)
@MainActor
enum LaunchFolder {
    private static var used = false

    static func take() -> URL? {
        guard !used else { return nil }
        used = true
        guard let path = UserDefaults.standard.string(forKey: "KilnFolder") else { return nil }
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
        guard url.standardizedFileURL != Kiln.chatFolder.standardizedFileURL else { return }
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
                Text("kiln has its own inference engine. Download a model once and work fully offline.")
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
