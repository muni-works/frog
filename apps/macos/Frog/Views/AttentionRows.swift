import SwiftUI

/// The attention tree's rows (docs/design/sidebar-refactor.md §5), in three weights: a manager
/// (an 18 pt monogram and a semibold title while anything under it is live), a live worker
/// (regular, no monogram: the width goes to the title), and settled work (smaller, muted, its
/// age instead of a spinner). State color lives on the glyph only.
enum AttentionMetrics {
    /// Indent per level: one column per ancestor, and the same number in both list densities
    /// (the compact list used to indent 8 pt where this list used 14, for the same tree).
    static let indent: CGFloat = 14
    /// Levels that get the full step. Past these, steps shrink instead of the tree flattening:
    /// a fifth-level worker still sits visibly deeper than a fourth.
    static let fullDepth = 4
    /// The smallest step a deeper level may get. Never zero — two levels must never share a
    /// leading, or the tree stops saying how deep a row is.
    static let minStep: CGFloat = 4
    /// The disclosure column every row reserves, so titles line up whether or not they fold.
    static let disclosure: CGFloat = 14
    static let monogram: CGFloat = 18
    static let rowHeight: CGFloat = 24

    /// How far right a row at `depth` starts.
    ///
    /// There is no clamp. `SessionNesting` reports real depth, and this spends it: the first
    /// four levels take a full 14 pt column each, then each further level takes `56 / depth`
    /// (11.2 pt at the fifth, 9.3 at the sixth, easing to `minStep`), so indentation keeps
    /// growing without ever eating a title's width. The old cap lined a fifth-level row up on
    /// the fourth's rail with nothing to say they were different.
    static func leading(_ depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        return (1...depth).reduce(0) { x, level in x + step(level) }
    }

    /// The column one level takes. Full width down to `fullDepth`, narrowing after, never 0.
    static func step(_ level: Int) -> CGFloat {
        level <= fullDepth ? indent : max(minStep, indent * CGFloat(fullDepth) / CGFloat(level))
    }

    /// The centre of the column at `level` (1-based), where its rail is drawn. Every level's
    /// rail sits in the middle of its own step, so a column lines up down the whole tree even
    /// where the steps narrow.
    static func columnX(_ level: Int) -> CGFloat {
        leading(level - 1) + step(level) / 2
    }

    /// The gap a rail strip leaves between its last column and the title, inside the row, and
    /// the room a top-level row's content keeps from its edge.
    static let inset: CGFloat = 4
    /// How wide a rail strip must be to cover a row at `depth`: every indent column, plus the
    /// inset the elbow points into, plus a little past it.
    static func railWidth(_ depth: Int) -> CGFloat { leading(depth) + inset + 2 }

    /// Where an elbow meets the row's first line of text, from the row's top: the vertical
    /// padding, then half the first line's height.
    static func elbow(firstLine: CGFloat) -> CGFloat { 5 + firstLine }
    /// How far the rails overhang their row at each end, to cross the stack's spacing.
    static let railBleed: CGFloat = 3
}

/// The started-by guide over a list that lays its own rows out (the by-date list): the rails
/// are drawn in a strip at the row's leading edge, over its whole height, so the tree reads
/// as one line down the page. The strip is exactly `railWidth(depth)` and the row is padded by
/// that much, so the rails land in the same columns `TreeRow` uses.
struct TreeRailRow<Content: View>: View {
    let guide: SessionNesting.Guide
    /// Where the elbow meets the title, from the row's top.
    var elbowY: CGFloat? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if guide.depth > 0 {
                TreeRails(guide: guide, elbowY: elbowY ?? 12)
                    .frame(width: AttentionMetrics.railWidth(guide.depth))
            }
            content()
        }
    }
}

/// The started-by tree's rails: in a file tree's language, a vertical through every ancestor
/// column that has more to come below, and an elbow into the row's own title.
///
/// Drawn on the sidebar's ground, in the indent column, with the selection pill inset past it
/// (see `TreeRow.selectionFill`) — a selected nested row used to swallow its own guide.
struct TreeRails: View {
    let guide: SessionNesting.Guide
    /// Where within the strip the elbow meets the title (the row's own first line).
    var elbowY: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            Canvas { ctx, size in
                guard guide.depth > 0 else { return }
                let bottom = size.height
                var p = Path()

                // Ancestors: a full column each, while that ancestor still has something below.
                for level in 1..<guide.depth where guide.rail(level - 1) {
                    let x = AttentionMetrics.columnX(level) - 0.5
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: bottom))
                }

                // The row's own column: down to its title's line, then the arm into the title.
                let x = AttentionMetrics.columnX(guide.depth) - 0.5
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: elbowY))
                p.addLine(to: CGPoint(x: size.width, y: elbowY))
                // └ ends at the elbow unless children hang below; ├ runs on to its sibling.
                if guide.continues || !guide.last {
                    p.move(to: CGPoint(x: x, y: elbowY))
                    p.addLine(to: CGPoint(x: x, y: bottom))
                }
                ctx.stroke(p, with: .color(Tokens.line), lineWidth: 1)
            }
            // Taller than the row by the bleed at each end, and pulled up to match, so the
            // columns cross the stack's spacing rather than stopping at every row's edge.
            .frame(height: h + AttentionMetrics.railBleed * 2)
            .offset(y: -AttentionMetrics.railBleed)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TreeRow<Menu: View>: View {
    let session: SessionInfo
    /// How its children stand, and whether they're folded into it.
    let counts: SessionNesting.Counts
    let collapsed: Bool
    let state: SessionNesting.State
    let selected: Bool
    /// Where it sits and what its guide draws. A root has no rails.
    var guide = SessionNesting.Guide.root
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
    private var depth: Int { guide.depth }

    var body: some View {
        HStack(spacing: 0) {
            // The rail strip: exactly where the by-date list puts it, so the two list modes
            // draw the same columns for the same tree.
            if depth > 0 {
                Color.clear.frame(width: AttentionMetrics.railWidth(depth))
            }
            disclosure
            title
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isButton)
            trailing
        }
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: AttentionMetrics.rowHeight)
        .background { selectionFill }
        // Drawn past the row's own bounds so the columns bridge the stack's 1 pt spacing (a
        // Canvas is clipped to its frame, so it has to be given the extra height, not just
        // asked to draw outside it).
        .overlay(alignment: .topLeading) {
            if depth > 0 {
                TreeRails(guide: guide, elbowY: AttentionMetrics.elbow(firstLine: 7))
                    .frame(width: AttentionMetrics.railWidth(depth))
            }
        }
        // The whole row opens it, padding included; the disclosure and menu buttons inside
        // keep their own clicks.
        .contentShape(.rect)
        .onTapGesture(perform: open)
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
        if !session.model.isEmpty { parts.append(Workspace.modelName(session.model)) }
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
        if let status = RowStatus.of(state, prs: line.prs) {
            RowStatusView(status: status).fixedSize()
        } else if pinned {
            Image(systemName: "pin.fill").font(.frog(size: 9)).foregroundStyle(Tokens.textTertiary).help("pinned")
        }
    }

    /// The row's own fill, starting past its guide's columns and the tick that meets them
    /// (both drawn on the sidebar's ground): a selected nested row keeps the guide that says
    /// where it sits, instead of covering it with the pill.
    private var selectionFill: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: AttentionMetrics.leading(depth) + AttentionMetrics.inset)
            Color.clear
                .frame(maxWidth: .infinity)
                .background(selected || hovering ? Tokens.hover : Color.clear, in: .rect(cornerRadius: 6))
                .padding(.trailing, 4)
        }
        .padding(.vertical, 1)
    }

    private var helpText: String {
        var parts = [session.displayTitle]
        if let wt = SessionList.worktreeName(session.folder) { parts.append(wt) }
        else if let f = session.folder, !session.isChat { parts.append(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        if collapsed, let s = counts.summary { parts.append(s) }
        if !session.model.isEmpty { parts.append(Workspace.modelName(session.model)) }
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
