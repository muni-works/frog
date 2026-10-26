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
            if depth == 0 && monogram {
                Monogram(session: session, size: AttentionMetrics.monogram, selected: false, live: nil)
                    .padding(.trailing, 7)
            }
            title
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
            trailing
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .frame(height: AttentionMetrics.rowHeight)
        .background(background, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .paneDraggable(.session(session), title: session.displayTitle)
        .help(helpText)
    }

    @ViewBuilder
    private var disclosure: some View {
        if hasKids, let onToggle {
            Button(action: onToggle) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
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
        HStack(spacing: 6) {
            Text(highlighted)
                .font(.system(size: settledWeight ? 12 : 13, weight: manager && liveUnder ? .semibold : .regular))
                .foregroundStyle(Color.primary.opacity(titleOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
            if collapsed, let summary = counts.summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
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
            if let pane {
                Text("\(pane)").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary).help("In pane \(pane)")
            }
            if state.settled {
                Text(SessionAgeShort.age(session.modifiedDate, now: .now))
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ZStack {
                glyph.opacity(hovering ? 0 : 1)
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10)).frame(width: 14, height: 18).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 14)
        }
    }

    @ViewBuilder
    private var glyph: some View {
        AttentionGlyph(state: state, end: session.end, nested: depth > 0, pinned: pinned)
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(.tint.opacity(0.22)) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
        return AnyShapeStyle(.clear)
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
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary).help("pinned")
            } else if nested && end == .complete {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
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
                Text(session.displayTitle).font(.system(size: 13)).lineLimit(1)
                Text(ask).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(SessionAgeShort.age(session.modifiedDate, now: .now))
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.22)) : hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
        .paneDraggable(.session(session), title: session.displayTitle)
        .help("\(session.displayTitle)\n\(ask)")
    }
}
