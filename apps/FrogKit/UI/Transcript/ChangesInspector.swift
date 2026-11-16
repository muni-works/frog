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

/// The inspector's Changes tab: "N files +a −d" with Expand all, each changed file as a row
/// that opens to its diffs, and Commit and Open PR (or Push) at the bottom. The same order and
/// metrics as the web's `.files-head`, `.file-row` and `.insp-acts`.
struct ChangesInspector: View {
    let conversation: Conversation
    let maxHeight: CGFloat
    /// The composer tray's Commit; nil where there's nothing to commit to (a chat, the phone).
    var commit: (() -> Void)?
    /// The tray's Open PR, or Push once a PR is bound (`hasPr`); nil without a repo.
    var pr: (() -> Void)?
    var hasPr = false
    /// Files open to their diffs. A lone file opens by itself.
    @State private var open: Set<String> = []

    var body: some View {
        let changes = conversation.sessionChanges
        if changes.isEmpty {
            InspectorEmpty(symbol: "plusminus", title: "No changes yet", detail: "Files Frog edits show up here.")
        } else {
            let actions = commit != nil || pr != nil
            VStack(spacing: 0) {
                header(changes)
                HuggingScroll(maxHeight: max(60, maxHeight - 40 - (actions ? 52 : 0))) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes) { change in
                            FileRow(change: change, open: open.contains(change.path)) { toggle(change.path) }
                                .fileActions(change.path)
                            if open.contains(change.path) {
                                diffs(change)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                Spacer(minLength: 0)
                if actions {
                    HStack(spacing: 8) {
                        if let commit {
                            Button("Commit", action: commit).buttonStyle(InspectorButtonStyle(kind: .bordered))
                        }
                        if let pr {
                            Button(hasPr ? "Push" : "Open PR", action: pr).buttonStyle(InspectorButtonStyle(kind: .prominent))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .task(id: changes.count == 1 ? changes[0].path : nil) {
                if changes.count == 1 { open = [changes[0].path] }
            }
        }
    }

    private func header(_ changes: [FileChange]) -> some View {
        HStack(spacing: 8) {
            Text("\(changes.count) file\(changes.count == 1 ? "" : "s")")
                .font(.frog(size: Tokens.Size.status, weight: .semibold))
                .foregroundStyle(Tokens.text)
            Text("+\(changes.reduce(0) { $0 + $1.added })").foregroundStyle(Tokens.accent)
            Text("−\(changes.reduce(0) { $0 + $1.removed })").foregroundStyle(Tokens.warn)
            Spacer(minLength: 0)
            Button(open.isEmpty ? "Expand all" : "Collapse all") {
                open = open.isEmpty ? Set(changes.map(\.path)) : []
            }
            .buttonStyle(InspectorButtonStyle(kind: .plain))
        }
        .font(.frog(size: Tokens.Size.meta, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func diffs(_ change: FileChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(change.diffs.enumerated()), id: \.offset) { i, diff in
                if change.diffs.count > 1 {
                    Text("Edit \(i + 1) of \(change.diffs.count)")
                        .font(.frog(size: Tokens.Size.meta, weight: .semibold))
                        .foregroundStyle(Tokens.textSecondary)
                }
                DiffView(diff: diff)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func toggle(_ path: String) {
        if open.contains(path) { open.remove(path) } else { open.insert(path) }
    }
}

/// One changed file: its icon, name and directory (truncated from the head), and its counts.
private struct FileRow: View {
    let change: FileChange
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: change.created ? "doc.badge.plus" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(change.created ? Tokens.accent : Tokens.textTertiary)
                    .frame(width: 14)
                Text(change.name)
                    .font(.frog(size: Tokens.Size.status, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                let dir = (change.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir)
                        .font(.frog(size: Tokens.Size.meta, design: .monospaced))
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                Group {
                    Text("+\(change.added)").foregroundStyle(Tokens.accent)
                    Text("−\(change.removed)").foregroundStyle(Tokens.warn)
                }
                .font(.frog(size: Tokens.Size.meta, design: .monospaced))
                .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(hovering || open ? Tokens.hover : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(change.path)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}
