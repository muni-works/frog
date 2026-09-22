import SwiftUI

extension Conversation {
    /// Every file changed in this session, in first-touched order, with each edit's diff.
    var sessionChanges: [FileChange] {
        var out: [FileChange] = []
        for turn in turns {
            for change in TurnParts(turn).changes {
                if let i = out.firstIndex(where: { $0.path == change.path }) {
                    out[i].diffs += change.diffs
                } else {
                    out.append(change)
                }
            }
        }
        return out
    }
}

struct ChangesInspector: View {
    let conversation: Conversation
    @State private var selection: String?

    var body: some View {
        let changes = conversation.sessionChanges
        let current = changes.first { $0.path == selection } ?? changes.first
        // One scroll view with a fixed frame: content-dependent sizes here feed back into the
        // split view's column constraints and can loop the layout.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if changes.isEmpty {
                    ContentUnavailableView(
                        "No Changes Yet",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Files kiln edits in this session show up here.")
                    )
                    .padding(.top, 60)
                } else {
                    HStack {
                        Text("\(changes.count) file\(changes.count == 1 ? "" : "s") changed")
                            .font(.headline)
                        Spacer()
                        Text("+\(changes.reduce(0) { $0 + $1.added })").foregroundStyle(.green)
                        Text("−\(changes.reduce(0) { $0 + $1.removed })").foregroundStyle(.red)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspectorColumnWidth(min: 300, ideal: 400, max: 640)
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
