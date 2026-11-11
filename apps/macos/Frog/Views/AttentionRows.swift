import SwiftUI

/// The attention tree's rows (docs/design/sidebar-refactor.md §5), in three weights: a manager
/// (an 18 pt monogram and a semibold title while anything under it is live), a live worker
/// (regular, no monogram: the width goes to the title), and settled work (smaller, muted, its
/// age instead of a spinner). State color lives on the glyph only.
enum AttentionMetrics {
    /// Indent per level; `SessionNesting.maxDepth` caps it.
    static let indent: CGFloat = 14
    /// The disclosure column every row reserves, so titles line up whether or not they fold.
    static let disclosure: CGFloat = 14
    static let monogram: CGFloat = 18
    static let rowHeight: CGFloat = 24

    static func leading(_ depth: Int) -> CGFloat { CGFloat(min(depth, SessionNesting.maxDepth)) * indent }
}

struct TreeRow<Menu: View>: View {
    let session: SessionInfo
    let depth: Int
    /// How its children stand, and whether they're folded into it.
    let counts: SessionNesting.Counts
    let collapsed: Bool
    let state: SessionNesting.State
    let selected: Bool
    var pinned = false
    /// The pane showing it, when the window is split.
    var pane: Int? = nil
    /// Search text to highlight in the title (lowercased).
    var highlight = ""
    /// Top-level rows show their monogram; a flat list (archive matches) doesn't.
    var monogram = true
    var onToggle: (() -> Void)? = nil
    /// Its git badge (its own tree, or its subtree's sum), when there's one to show.
    var git: GitRowBadge? = nil
    /// The second line and status, as the web shows them.
    var line = RowLine()
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    private var hasKids: Bool { counts.total > 0 }
    private var liveSelf: Bool { !state.settled }
    private var liveUnder: Bool { liveSelf || counts.waiting + counts.running + counts.unread > 0 }
    private var manager: Bool { depth == 0 && hasKids }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: AttentionMetrics.leading(depth))
            disclosure
            title
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
            trailing
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: AttentionMetrics.rowHeight)
        .background(background, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .paneDraggable(.session(session), title: session.displayTitle)
        .help(helpText)
        // A row on screen asks for its tree's status (queued off the main thread, at most once
        // a minute); drawing it never runs git.
        .task(id: session.id) { GitIndex.shared.wantStatus(session) }
    }

    @ViewBuilder
    private var disclosure: some View {
        if hasKids, let onToggle {
            Button(action: onToggle) {
                Image(systemName: "chevron.right").font(.frog(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: AttentionMetrics.disclosure, height: AttentionMetrics.rowHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(collapsed ? "Show the sessions this one started" : "Fold the sessions this one started")
        } else {
            Color.clear.frame(width: AttentionMetrics.disclosure)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(highlighted)
                    .font(.frog(size: Tokens.Size.secondary, weight: manager && liveUnder ? .semibold : .regular))
                    .foregroundStyle(Tokens.text.opacity(titleOpacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if collapsed, let summary = counts.summary {
                    Text(summary)
                        .font(.frog(size: Tokens.Size.meta))
                        .foregroundStyle(Tokens.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Text(second)
                .font(.frog(size: Tokens.Size.meta))
                .foregroundStyle(line.text == nil ? Tokens.textTertiary : line.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// What it's doing now or its last reply; idle, repo · turns · model. No timestamps.
    private var second: String {
        if let t = line.text, !t.isEmpty { return t }
        var parts: [String] = []
        if session.isChat { parts.append("Chat") }
        else if let f = SessionList.worktreeName(session.folder) ?? session.folder?.lastPathComponent { parts.append(f) }
        if let n = line.turns, n > 0 { parts.append("\(n) turn\(n == 1 ? "" : "s")") }
        if !session.model.isEmpty { parts.append(ModelIdentity.cleanName(session.model).name) }
        return parts.joined(separator: " · ")
    }

    /// Settled work reads quieter; a top-level row keeps its size so the monograms line up.
    private var settledWeight: Bool { !liveUnder && !selected && depth > 0 }

    private var titleOpacity: Double {
        if selected || liveSelf { return 1 }
        if manager && liveUnder { return 1 }
        return depth == 0 ? 0.8 : 0.55
    }

    private var highlighted: AttributedString {
        var a = AttributedString(session.displayTitle)
        guard !highlight.isEmpty, let r = a.range(of: highlight, options: .caseInsensitive) else { return a }
        a[r].foregroundColor = .accentColor
        a[r].backgroundColor = Color.accentColor.opacity(0.16)
        return a
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if let git {
                GitBadgeView(display: git.display, muted: !liveUnder && !selected, help: git.help, card: git.card)
            }
            if let pane {
                Text("\(pane)").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary).help("In pane \(pane)")
            }
            ZStack {
                glyph.opacity(hovering ? 0 : 1)
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.frog(size: 10)).frame(width: 14, height: 18).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(minWidth: 14, alignment: .trailing)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var glyph: some View {
        if let status = RowStatus.of(state, pr: line.pr) {
            RowStatusView(status: status).fixedSize()
        } else if pinned {
            Image(systemName: "pin.fill").font(.frog(size: 9)).foregroundStyle(Tokens.textTertiary).help("pinned")
        }
    }

    /// As on the web: the row you're on and the row under the pointer share one quiet fill.
    private var background: AnyShapeStyle {
        AnyShapeStyle(selected || hovering ? Tokens.hover : .clear)
    }

    private var helpText: String {
        var parts = [session.displayTitle]
        if let wt = SessionList.worktreeName(session.folder) { parts.append(wt) }
        else if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if collapsed, let s = counts.summary { parts.append(s) }
        parts.append(session.model)
        return parts.joined(separator: "\n")
    }
}

/// The background-work vocabulary: a spinner while running, an orange dot waiting on you, an
/// accent dot finished unseen, a red dot failed; settled, a check when nested and a hollow ring
/// when idle at the top.
struct AttentionGlyph: View {
    let state: SessionNesting.State
    let end: SessionInfo.End?
    var nested = false
    var pinned = false

    var body: some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12).help("working")
        case .waiting:
            Circle().fill(.orange).frame(width: 7, height: 7)
                .background(Circle().fill(.orange.opacity(0.25)).frame(width: 12, height: 12))
                .help("waiting on you")
        case .unread:
            Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("finished while you were away")
        case .failed:
            Circle().fill(.red).frame(width: 6, height: 6).help("ended with an error")
        case .done:
            if pinned {
                Image(systemName: "pin.fill").font(.frog(size: 9)).foregroundStyle(.tertiary).help("pinned")
            } else if nested && end == .complete {
                Image(systemName: "checkmark").font(.frog(size: 9, weight: .bold))
                    .foregroundStyle(.green.opacity(0.75)).help("done")
            } else {
                Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 9, height: 9).help("idle")
            }
        }
    }
}

/// A row in the needs-you lens: the title, and under it what the session wants, oldest first.
struct NeedsYouRow<Menu: View>: View {
    let session: SessionInfo
    /// What it's asking, in a line.
    let ask: String
    let selected: Bool
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.orange).frame(width: 7, height: 7)
                .background(Circle().fill(.orange.opacity(0.25)).frame(width: 12, height: 12))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle).font(.frog(size: 13)).lineLimit(1)
                Text(ask).font(.frog(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionAgeShort.age(session.modifiedDate, now: .now))
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(selected || hovering ? Tokens.hover : .clear,
                    in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .paneDraggable(.session(session), title: session.displayTitle)
        .help("\(session.displayTitle)\n\(ask)")
    }
}
