import AppKit
import SwiftUI

/// The folder a conversation works in, as a chip above the composer. The menu lists recent
/// folders and a chooser. `choose` handles the pick; without it, a pick opens a new tab there.
struct FolderChip: View {
    /// Nil (or the chat folder): a plain chat, no folder.
    let folder: URL?
    /// Handles a pick (nil = no folder). Without it, a pick opens a new tab there.
    var choose: ((URL?) -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            let recents = Recents.all.filter { $0 != current }
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents.prefix(8), id: \.self) { url in
                        Button {
                            pick(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "folder")
                        }
                    }
                }
            }
            Button("Choose Folder…") {
                if let url = FolderPanel.run() { pick(url) }
            }
            if current != nil {
                Button("No Folder (Plain Chat)") { pick(nil) }
            }
            if let folder = current {
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: current == nil ? "bubble.left" : "folder")
                Text(current?.lastPathComponent ?? "No folder")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(current.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "A plain chat, without a project folder. Pick a folder to let kiln work on code.")
    }

    private var current: URL? {
        guard let folder, !Kiln.isChat(folder) else { return nil }
        return folder
    }

    private func pick(_ url: URL?) {
        if let choose { choose(url) } else { openWindow(value: url ?? Kiln.chatFolder) }
    }
}

enum FolderPanel {
    @MainActor
    static func run() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder kiln works in"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

