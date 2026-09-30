import AppKit
import QuickLook
import SwiftUI

extension View {
    /// Pro-app file affordances for a path shown in the UI: a context menu (open in editor,
    /// reveal, Quick Look, copy path), drag out as a real file, and Quick Look.
    func fileActions(_ path: String) -> some View {
        modifier(FileActions(path: path))
    }
}

private struct FileActions: ViewModifier {
    let path: String
    @Environment(\.projectFolder) private var folder
    @State private var preview: URL?

    private var url: URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return (folder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appending(path: path)
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Open in \(Editor.preferred?.name ?? "Default App")", systemImage: "arrow.up.forward.app") {
                    Editor.open([url])
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Quick Look", systemImage: "eye") { preview = url }
                Divider()
                Button("Copy Path", systemImage: "doc.on.doc") { copy(url.path) }
                Button("Copy Relative Path") { copy(path) }
            }
            .draggable(url)
            .quickLookPreview($preview)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
