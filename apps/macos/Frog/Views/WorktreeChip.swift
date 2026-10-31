import AppKit
import SwiftUI

/// The composer's worktree control, beside the folder chip before the first message: the
/// repo's worktrees, with "New Worktree…" to make one. Picking one starts the conversation
/// there (a fresh session — a running session stays in its tree).
struct WorktreeChip: View {
    let repo: URL
    /// Starts the conversation in the picked worktree folder.
    var start: (URL) -> Void

    @State private var index: WorktreeIndex?
    @State private var creating = false

    var body: some View {
        Menu {
            let trees = index?.trees ?? []
            if !trees.isEmpty {
                ForEach(trees) { tree in
                    Button {
                        start(tree.folder)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tree.isMain ? "folder" : "arrow.triangle.branch")
                            Text(tree.isMain ? "main checkout" : tree.name)
                            if let owner = tree.owner {
                                Text("· busy: \(owner)")
                            } else if tree.dirty {
                                Text("· dirty")
                            }
                        }
                        .font(.frog(size: 12))
                    }
                    .disabled(tree.owner != nil)
                }
                Divider()
            }
            Button {
                newWorktree()
            } label: {
                Label("New Worktree…", systemImage: "plus")
            }
            .disabled(creating)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text("Worktree")
                Image(systemName: "chevron.down").font(.frog(size: 9, weight: .semibold))
            }
            .font(.frog(size: 12))
            .foregroundStyle(.secondary)
            .hoverPlate()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start this conversation in a git worktree: its own folder and branch, so parallel sessions never mix work.")
        .onAppear { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        if index == nil { index = WorktreeIndex(repo: repo) }
        await index?.refresh()
    }

    private func newWorktree() {
        // A sheet-less inline ask: the field alert gives the tree its name.
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText = "A folder under \(repo.path)/.frog/worktrees, on a new branch from \(index?.baseRef ?? "the remote default")."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "name (e.g. fix-composer)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        creating = true
        let name = field.stringValue
        Task {
            defer { creating = false }
            guard let index, let dir = try? await index.create(named: name) else { return }
            start(dir)
        }
    }
}
