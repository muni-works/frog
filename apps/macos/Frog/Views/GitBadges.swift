import AppKit
import SwiftUI

/// A sidebar row's git badge (docs/design/sidebar-git/README.md §1): a purple branch glyph
/// with the commits ahead (a dot on it when the settled tree is dirty), a green merge glyph
/// (alone on a leaf, with a count on a group), amber when stuck mid-rebase. Resting on it opens
/// the hover card; clicking pins the card.
struct GitBadgeView: View {
    let display: GitBadge.Display
    var muted = false
    /// The tooltip when there's no card (or before it opens).
    var help: String
    /// What the hover card lists; nil for no card.
    var card: GitCardController.Request?
    @State private var anchor = AnchorBox()
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if display.showsBranch {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(branchTint)
                        .overlay(alignment: .topTrailing) {
                            if display.dirty {
                                Circle().fill(branchTint).frame(width: 4.5, height: 4.5)
                                    .overlay(Circle().stroke(.background, lineWidth: 1))
                                    .offset(x: 2.5, y: -1.5)
                            }
                        }
                    if let n = display.ahead { digits(n).foregroundStyle(display.trouble != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary)) }
                }
            }
            if display.landed > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                    if !display.leaf { digits(display.landed).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(hot ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
        .padding(.horizontal, -3)
        .opacity(muted && !hot ? 0.7 : 1)
        .fixedSize()
        .background(AnchorView(box: anchor))
        .contentShape(.rect)
        .onHover { inside in
            hovering = inside
            guard let card else { return }
            if inside { GitCardController.shared.enterBadge(card, anchor: anchor) } else { GitCardController.shared.leaveBadge(card.id) }
        }
        .onTapGesture {
            guard let card else { return }
            GitCardController.shared.toggle(card, anchor: anchor)
        }
        .onDisappear { if let card { GitCardController.shared.rowGone(card.id) } }
        .help(card == nil ? help : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(card == nil ? [] : .isButton)
        .accessibilityAction(named: "Show landed work") {
            if let card { GitCardController.shared.toggle(card, anchor: anchor) }
        }
    }

    private var hot: Bool { hovering && card != nil || (card.map { GitCardController.shared.current?.id == $0.id } ?? false) }

    private var branchTint: Color {
        if display.trouble != nil { return .orange }
        if display.detached { return Color.secondary.opacity(0.6) }
        return .purple
    }

    private func digits(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 11, design: .rounded).monospacedDigit())
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let a = display.ahead { parts.append("\(a) commit\(a == 1 ? "" : "s") ahead") }
        if display.dirty { parts.append("uncommitted changes") }
        if let t = display.trouble { parts.append(t.words) }
        if display.landed > 0 { parts.append(display.leaf ? "landed" : "\(display.landed) landed") }
        return parts.joined(separator: ", ")
    }
}

/// What a sidebar row hands its badge: the glyphs, the tooltip, and the card behind it.
struct GitRowBadge {
    var display: GitBadge.Display
    var help: String
    var card: GitCardController.Request?
}

/// The attention tree's badges (§2): a leaf shows its own tree, a manager its whole subtree's
/// sum, a done fold its folded children's. Built per sidebar pass from the index: lookups and
/// sums, no git.
@MainActor
struct GitTreeBadges {
    var rows: [String: GitRowBadge] = [:]
    var folds: [String: GitRowBadge] = [:]

    static func build(_ entries: [SessionNesting.Entry], heads: [SessionInfo], parentOf: [String: String],
                      folds: [String: SessionFolds.Fold], chief: String?,
                      state: (SessionInfo) -> SessionNesting.State,
                      open: @escaping (SessionInfo) -> Void) -> GitTreeBadges {
        let byId = Dictionary(heads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kids: [String: [String]] = [:]
        for h in heads { if let p = parentOf[h.id], byId[p] != nil { kids[p, default: []].append(h.id) } }
        let children: (String) -> [String] = { key in
            if key == AttentionTree.chiefFold { return heads.filter { parentOf[$0.id] == chief && $0.id != chief }.map(\.id) }
            if key == AttentionTree.yoursFold {
                return heads.filter { s in s.id != chief && (parentOf[s.id].map { byId[$0] == nil } ?? true) }.map(\.id)
            }
            return kids[key] ?? []
        }
        let members: (String) -> [SessionInfo] = { id in
            guard let s = byId[id] else { return [] }
            return [s] + (folds[id]?.older ?? [])
        }
        func settled(_ s: SessionInfo) -> Bool { Self.settled(state(s)) }
        func group(_ ids: [String], title: String) -> GitRowBadge? {
            Self.group(ids.flatMap { GitRollup.subtree($0, children: children) }.flatMap(members),
                       id: "git:" + title + ids.joined(), title: title, settled: settled, open: open)
        }

        var out = GitTreeBadges()
        for e in entries {
            switch e {
            case .row(let s, _, let counts, _):
                if counts.total > 0 {
                    out.rows[s.id] = group([s.id], title: s.displayTitle)
                } else {
                    out.rows[s.id] = leaf(s, members: members(s.id), settled: settled(s), open: open)
                }
            case .done:
                break
            }
        }
        for (parent, ids) in GitRollup.foldMembers(entries, children: children) where !ids.isEmpty {
            let title = parent == AttentionTree.chiefFold ? "Done by chief"
                : parent == AttentionTree.yoursFold ? "Your finished sessions"
                : "\(byId[parent]?.displayTitle ?? "Finished") · done"
            out.folds[parent] = group(ids, title: title)
        }
        return out
    }

    /// One session's badge: its own tree (older sessions of its branch included in the card).
    static func leaf(_ s: SessionInfo, members: [SessionInfo], settled: Bool,
                     open: @escaping (SessionInfo) -> Void) -> GitRowBadge? {
        let index = GitIndex.shared
        guard let b = index.badge(s), let d = b.display(settled: settled) else { return nil }
        var counts: [String] = []
        if let a = b.ahead, a > 0 { counts.append("\(a) ahead") }
        if b.isLanded { counts.append("landed") }
        if let t = b.trouble { counts.append(t.words) }
        return GitRowBadge(
            display: d, help: b.summary,
            card: .init(id: "git:" + s.id, title: s.displayTitle, sessions: members, single: true,
                        counts: counts.joined(separator: " · "), open: open,
                        refresh: { index.refreshFromRemote(members, askGitHub: true) }))
    }

    /// A group's badge: the sum over `sessions` (a subtree, a fold, a repo), one tree once.
    static func group(_ sessions: [SessionInfo], id: String, title: String, settled: (SessionInfo) -> Bool,
                      open: @escaping (SessionInfo) -> Void) -> GitRowBadge? {
        let index = GitIndex.shared
        let items = sessions.compactMap { s in index.badge(s).map { (badge: $0, settled: settled(s)) } }
        let sum = GitSummary.of(items)
        guard let d = sum.display else { return nil }
        var counts: [String] = []
        if sum.landed > 0 { counts.append("\(sum.landed) landed") }
        if sum.ahead > 0 { counts.append("\(sum.ahead) ahead") }
        var help = counts
        if sum.dirty { help.append("uncommitted work left behind") }
        if sum.trouble { help.append("a rebase or merge is stuck") }
        return GitRowBadge(display: d, help: help.joined(separator: " · "),
                           card: .init(id: id, title: title, sessions: sessions, single: false,
                                       counts: counts.joined(separator: " · "), open: open,
                                       refresh: { index.refreshFromRemote(sessions, askGitHub: false) }))
    }

    /// Whether a session counts as settled for its badge: not running, not mid-turn on you.
    static func settled(_ state: SessionNesting.State) -> Bool { state != .running && state != .waiting }
}

/// The badge's view, for placing the card (a weak box: SwiftUI owns the view).
final class AnchorBox {
    weak var view: NSView?

    /// The badge's frame on screen.
    var screenRect: NSRect? {
        guard let v = view, let w = v.window else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
}

private struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

// MARK: - The hover card's lifecycle

/// One hover card at a time (§3b lifecycle): it opens after the pointer rests on a badge for
/// 500 ms, stays while the pointer is on the badge or the card (a 300 ms grace covers the gap),
/// moves to another badge with no delay while warm, and pins on click. A hover card never
/// takes focus; a pinned one does (arrows, Return, ⌘C, Esc).
@MainActor
@Observable
final class GitCardController {
    static let shared = GitCardController()

    struct Request {
        /// The row's id: one card per row.
        var id: String
        var title: String
        /// The sessions it stands for: a group's subtree, or one session.
        var sessions: [SessionInfo]
        /// One session's card (its own commits under Not landed), not a group's.
        var single: Bool
        /// The header's numbers, as the row's badge has them.
        var counts: String
        var open: (SessionInfo) -> Void
        var refresh: () -> Void
    }

    private(set) var current: Request?
    private(set) var pinned = false
    @ObservationIgnored private var panel: CardPanel?
    @ObservationIgnored private var anchor: AnchorBox?
    @ObservationIgnored private var overBadge: String?
    @ObservationIgnored private var overCard = false
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var closedAt = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let openDelay = Duration.milliseconds(500)
    static let grace = Duration.milliseconds(300)
    static let leaveCard = Duration.milliseconds(250)
    /// How long after a card closes the next badge opens at once.
    static let warm: TimeInterval = 1

    private init() {}

    func enterBadge(_ r: Request, anchor: AnchorBox) {
        overBadge = r.id
        closing?.cancel()
        if current?.id == r.id { return }
        if pinned { return }
        opening?.cancel()
        if current != nil || Date().timeIntervalSince(closedAt) < Self.warm {
            show(r, anchor: anchor)
            return
        }
        opening = Task {
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, overBadge == r.id else { return }
            show(r, anchor: anchor)
        }
    }

    func leaveBadge(_ id: String) {
        if overBadge == id { overBadge = nil }
        opening?.cancel()
        scheduleClose(Self.grace)
    }

    func enterCard() {
        overCard = true
        closing?.cancel()
    }

    func leaveCard() {
        overCard = false
        scheduleClose(Self.leaveCard)
    }

    /// A click on the badge: pin its card (it takes focus), or close it if it's pinned.
    func toggle(_ r: Request, anchor: AnchorBox) {
        opening?.cancel()
        if pinned, current?.id == r.id { close(); return }
        show(r, anchor: anchor)
        pinned = true
        panel?.allowKey = true
        panel?.makeKey()
    }

    /// The row went away (scope change, collapse, scrolled out): its card goes too.
    func rowGone(_ id: String) {
        if current?.id == id { close() }
    }

    func close() {
        opening?.cancel()
        closing?.cancel()
        guard current != nil else { return }
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        current = nil
        pinned = false
        overCard = false
        closedAt = Date()
        panel?.allowKey = false
    }

    private func scheduleClose(_ after: Duration) {
        guard !pinned else { return }
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: after)
            guard !Task.isCancelled, !overCard, overBadge == nil, !pinned else { return }
            close()
        }
    }

    private func show(_ r: Request, anchor box: AnchorBox) {
        guard let rect = box.screenRect, let window = box.view?.window else { return }
        current = r
        anchor = box
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        place(panel, below: rect, on: window.screen)
        panel.orderFront(nil)
        watch(window)
    }

    /// Below the badge (above it when the screen runs out), its leading edge near the badge.
    func place(_ panel: NSPanel, below rect: NSRect, on screen: NSScreen?) {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = screen?.visibleFrame ?? .infinite
        var x = rect.minX - 24
        var y = rect.minY - 4 - size.height
        if y < visible.minY { y = rect.maxY + 4 }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    /// Re-fit the panel after its content changed size (stats arrived).
    func refit() {
        guard let panel, let rect = anchor?.screenRect else { return }
        place(panel, below: rect, on: panel.screen)
    }

    private func makePanel() -> CardPanel {
        let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: GitCardHost())
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        p.onResignKey = { [weak self] in
            // A pinned card closes when focus goes elsewhere (a click outside).
            guard let self, self.pinned else { return }
            self.close()
        }
        return p
    }

    private func watch(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.pinned else { return }
                    self.close()
                }
            },
            nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
            nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            },
        ]
    }
}

/// A borderless panel that takes key only when its card is pinned.
final class CardPanel: NSPanel {
    var allowKey = false
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - The card

/// The panel's root: whatever card is current.
private struct GitCardHost: View {
    @State private var controller = GitCardController.shared

    var body: some View {
        if let r = controller.current {
            GitCard(request: r, pinned: controller.pinned)
                .id(r.id)
        }
    }
}

/// The hover card (§3b): what landed (title, Merged, repo#N or repo@sha, +N −M) and what
/// hasn't, for a group's children or one session. Rows open GitHub; ⌥-click opens the session.
struct GitCard: View {
    let request: GitCardController.Request
    var pinned = false
    @State private var index = GitIndex.shared
    @State private var focus: Int?
    @FocusState private var focused: Bool

    private var card: GitIndex.Card {
        index.card(request.sessions, landedLimit: request.single ? 10 : 8, pendingLimit: request.single ? 1 : 5)
    }

    var body: some View {
        let card = self.card
        let links = linkRows(card)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 12)
                Text(request.counts).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
            if !card.landed.isEmpty {
                section("Landed")
                ForEach(Array(card.landed.enumerated()), id: \.element.id) { i, l in
                    landedRow(l, focused: focus == i)
                }
                if card.moreLanded > 0 { more("\(card.moreLanded) more") }
            }
            if let p = card.pending.first, request.single {
                section("Not landed · " + (p.branch ?? "detached"))
                ownCommits(p)
            } else if !card.pending.isEmpty {
                section("Not landed")
                ForEach(Array(card.pending.enumerated()), id: \.element.id) { i, p in
                    pendingRow(p, focused: focus == card.landed.count + i)
                }
                if card.morePending > 0 { more("\(card.morePending) more") }
            }
            if card.landed.isEmpty && card.pending.isEmpty {
                Text("Nothing to show yet").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider().padding(.top, 6)
            HStack {
                Button("Refresh") { request.refresh() }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .help("Fetch the base and ask GitHub about this branch")
                Spacer()
                Text(pinned ? "↩ open · ⌘C copy · esc" : "click to pin").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .onHover { inside in
            if inside { GitCardController.shared.enterCard() } else { GitCardController.shared.leaveCard() }
        }
        .task(id: card) {
            index.load(card, commitsFor: request.single ? card.pending.first : nil)
        }
        // Commits or stats arriving change its height: the panel follows.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in GitCardController.shared.refit() }
        .focusable(pinned)
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { if pinned { focused = true } }
        .onChange(of: pinned) { _, on in if on { focused = true; focus = links.isEmpty ? nil : 0 } }
        .onKeyPress(.downArrow) { move(1, links.count); return .handled }
        .onKeyPress(.upArrow) { move(-1, links.count); return .handled }
        .onKeyPress(.return) {
            guard let i = focus, i < links.count else { return .ignored }
            activate(links[i], option: NSEvent.modifierFlags.contains(.option))
            return .handled
        }
        .onKeyPress(.escape) { GitCardController.shared.close(); return .handled }
        .onKeyPress(characters: ["c"]) { press in
            guard press.modifiers.contains(.command), let i = focus, i < links.count else { return .ignored }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links[i].url?.absoluteString ?? links[i].sha ?? "", forType: .string)
            return .handled
        }
        .onKeyPress(characters: ["r"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            request.refresh()
            return .handled
        }
    }

    private struct Link {
        var url: URL?
        var sha: String?
        var tree: String?
    }

    /// The rows arrows move through, in order.
    private func linkRows(_ card: GitIndex.Card) -> [Link] {
        card.landed.map { Link(url: $0.url, sha: $0.sha, tree: nil) }
            + (request.single ? [] : card.pending.map { Link(url: $0.url, sha: nil, tree: $0.id) })
    }

    private func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        focus = min(max((focus ?? (by > 0 ? -1 : count)) + by, 0), count - 1)
    }

    private func activate(_ link: Link, option: Bool) {
        if option || link.url == nil {
            if let s = session(forTree: link.tree) { request.open(s) }
        } else if let url = link.url {
            NSWorkspace.shared.open(url)
        }
        GitCardController.shared.close()
    }

    private func session(forTree tree: String?) -> SessionInfo? {
        guard let tree else { return request.single ? request.sessions.first : nil }
        return request.sessions.filter { GitIndex.shared.badge($0)?.tree == tree }.max { $0.modified < $1.modified }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).tracking(0.6)
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 2)
    }

    private func more(_ text: String) -> some View {
        Text("… " + text).font(.system(size: 11)).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func landedRow(_ l: GitIndex.Landed, focused: Bool) -> some View {
        CardRow(focused: focused, help: l.url?.absoluteString ?? "No GitHub link: \(l.sha ?? "squashed")") {
            if NSEvent.modifierFlags.contains(.option) {
                if let s = request.single ? request.sessions.first : nil { request.open(s) }
            } else if let url = l.url {
                NSWorkspace.shared.open(url)
            }
            GitCardController.shared.close()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text(l.title).lineLimit(1).truncationMode(.tail)
                if let s = l.session {
                    Text(s).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                MergedCapsule()
                Text(ref(l)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            .fixedSize()
            stat(l.statKey)
        }
    }

    private func ref(_ l: GitIndex.Landed) -> String {
        let slug = l.slug ?? ""
        if let n = l.pr { return "\(slug)#\(n)" }
        if let sha = l.sha { return slug.isEmpty ? sha : "\(slug)@\(sha)" }
        return "squashed"
    }

    private func pendingRow(_ p: GitIndex.Pending, focused: Bool) -> some View {
        CardRow(focused: focused, help: p.url?.absoluteString ?? "Not pushed: ⌥-click opens the session") {
            if NSEvent.modifierFlags.contains(.option) || p.url == nil {
                if let s = session(forTree: p.id) { request.open(s) }
            } else if let url = p.url {
                NSWorkspace.shared.open(url)
            }
            GitCardController.shared.close()
        } content: {
            Text(p.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if let b = p.branch {
                    Text(b).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 5).background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
                        .frame(maxWidth: 140, alignment: .trailing)
                }
                Text("↑\(p.ahead)").font(.system(size: 10.5, design: .monospaced))
            }
            .fixedSize(horizontal: false, vertical: true)
            if let t = p.trouble {
                Text(t.words).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.orange).frame(width: 84, alignment: .trailing)
            } else {
                stat(p.statKey)
            }
        }
    }

    @ViewBuilder
    private func ownCommits(_ p: GitIndex.Pending) -> some View {
        let list = p.commitsKey.flatMap { index.commits[$0] } ?? []
        ForEach(list) { c in
            HStack(spacing: 7) {
                Text(c.sha).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                Text(c.subject).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
        }
        if p.ahead > list.count, !list.isEmpty { more("\(p.ahead - list.count) more") }
        HStack(spacing: 0) {
            if let key = p.statKey, let s = index.stats[key] {
                Text("+\(s.added)").foregroundStyle(.green)
                Text(" −\(s.removed)").foregroundStyle(.red)
                Text(" · \(s.files) file\(s.files == 1 ? "" : "s") vs \(request.sessions.first.flatMap { GitIndex.shared.badge($0)?.base } ?? "base")")
                    .foregroundStyle(.secondary)
            } else {
                Text("…").foregroundStyle(.tertiary)
            }
            if let d = p.dirty, d > 0 { Text(" · ● \(d) uncommitted").foregroundStyle(.secondary) }
            else if p.dirty == 0 { Text(" · clean").foregroundStyle(.secondary) }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 12).padding(.top, 3)
    }

    @ViewBuilder
    private func stat(_ key: String?) -> some View {
        HStack(spacing: 5) {
            if let key, let s = index.stats[key] {
                Text("+\(s.added.formatted())").foregroundStyle(.green)
                Text("−\(s.removed.formatted())").foregroundStyle(.red)
            } else {
                Text(key == nil ? "" : "–").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .frame(width: 84, alignment: .trailing)
    }
}

/// One card row: the whole row is the button, highlighted under the pointer or the keyboard.
private struct CardRow<Content: View>: View {
    var focused: Bool
    var help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(hovering || focused ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .overlay {
                    if focused { RoundedRectangle(cornerRadius: 5).strokeBorder(.tint.opacity(0.55), lineWidth: 1.5) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "Merged", in the landed glyph's green (purple means ahead in these rows).
private struct MergedCapsule: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 8.5, weight: .bold))
            Text("Merged").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.leading, 4).padding(.trailing, 6).padding(.vertical, 1)
        .background(Color.green, in: .capsule)
    }
}
