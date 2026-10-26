import SwiftUI

extension Conversation {
    /// Every file changed in this session, in first-touched order, with each edit's diff.
    var sessionChanges: [FileChange] {
        var out: [FileChange] = []
        var at: [String: Int] = [:]
        for turn in turns {
            for change in changes(of: turn) {
                if let i = at[change.path] {
                    out[i].diffs += change.diffs
                } else {
                    at[change.path] = out.count
                    out.append(change)
                }
            }
        }
        return out
    }

    /// A turn's changes. A finished turn's only change when items are added to it, so they're
    /// kept: several views read `sessionChanges` on every event, and folding every turn each
    /// time was a fold of the whole session per event.
    func changes(of turn: TurnState) -> [FileChange] {
        if turn.finished, let hit = changesCache[turn.id], hit.count == turn.items.count { return hit.changes }
        let changes = TurnParts(turn).changes
        if turn.finished { changesCache[turn.id] = (turn.items.count, changes) }
        return changes
    }
}

struct ChangesInspector: View {
    let conversation: Conversation
    let maxHeight: CGFloat
    var collapse: (() -> Void)?
    @State private var selection: String?

    var body: some View {
        let changes = conversation.sessionChanges
        let current = changes.first { $0.path == selection } ?? changes.first
        HuggingScroll(maxHeight: maxHeight) {
            VStack(alignment: .leading, spacing: 12) {
                if changes.isEmpty {
                    ContentUnavailableView(
                        "No Changes Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Files frog edits in this session show up here.")
                    )
                    .padding(.vertical, 12)
                } else {
                    HStack {
                        Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                            .font(.headline)
                        Spacer()
                        Text("+\(changes.reduce(0) { $0 + $1.added })").foregroundStyle(.green)
                        Text("−\(changes.reduce(0) { $0 + $1.removed })").foregroundStyle(.red)
                        if let collapse {
                            Button(action: collapse) {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                            .help("Hide changes (⌥⌘0)")
                            .accessibilityLabel("Hide changes")
                        }
                    }
                    .font(.callout.monospacedDigit())
                    VStack(spacing: 2) {
                        ForEach(changes) { change in
                            Button {
                                selection = change.path
                            } label: {
                                FileRow(change: change)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        current?.path == change.path ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 8)
                                    )
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .fileActions(change.path)
                        }
                    }
                    if let change = current {
                        Divider()
                        ForEach(Array(change.diffs.enumerated()), id: \.offset) { i, diff in
                            if change.diffs.count > 1 {
                                Text("Edit \(i + 1) of \(change.diffs.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            DiffView(diff: diff)
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct FileRow: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: change.created ? "doc.badge.plus" : "doc.text")
                .foregroundStyle(change.created ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.name).lineLimit(1)
                let dir = (change.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text("+\(change.added)").foregroundStyle(.green)
            Text("−\(change.removed)").foregroundStyle(.red)
        }
        .font(.callout.monospacedDigit())
    }
}
