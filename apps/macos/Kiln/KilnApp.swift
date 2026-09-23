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

/// A window is either the welcome screen or one project folder.
struct RootView: View {
    @Binding var folder: URL?
    @State private var workspace: Workspace?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else {
                WelcomeView { folder = $0 }
                    .focusedSceneValue(\.openFolderHere) { folder = $0 }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            if folder == nil, let launched = LaunchFolder.take() { folder = launched }
        }
        .onChange(of: folder, initial: true) { _, url in
            workspace?.stop()
            workspace = url.map(Workspace.init)
            if let url { Recents.add(url) }
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
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(8)), forKey: key)
    }
}

struct WelcomeView: View {
    let open: (URL) -> Void
    @State private var picking = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange.gradient)
                Text("Kiln").font(.largeTitle.weight(.bold))
                Text("A local-first coding agent")
                    .foregroundStyle(.secondary)
            }
            Button {
                picking = true
            } label: {
                Label("Open Folder…", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .help("Open Folder (⌘O)")

            LocalModelCard()

            let recents = Recents.all
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 10)
                    ForEach(recents, id: \.self) { url in
                        Button {
                            open(url)
                        } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Spacer()
                                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 420)
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { open(url) }
        }
    }
}

/// First run: if no open model is on this Mac yet, offer the recommended one right on the
/// welcome screen. Once one is installed this shrinks to a line pointing at Settings.
private struct LocalModelCard: View {
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
