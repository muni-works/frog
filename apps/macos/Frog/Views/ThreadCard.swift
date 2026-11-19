import AppKit
import SwiftUI

/// The thread hover card (design: "Hover and metadata"): rest on a sidebar row for 900 ms and
/// a card opens beside the sidebar with what the thread is saying now, where it runs, on which
/// model, and how long ago. One card at a time; it never takes focus, a click on the row opens
/// the thread and closes it, and it stays out of the way of the git badge's own card.
@MainActor
@Observable
final class ThreadCardController {
    static let shared = ThreadCardController()

    struct Request {
        var session: SessionInfo
        var library: Library
        var open: () -> Void
    }

    private(set) var current: Request?
    @ObservationIgnored private var panel: CardPanel?
    @ObservationIgnored private var anchor: AnchorBox?
    @ObservationIgnored private var overRow: String?
    @ObservationIgnored private var overCard = false
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var closedAt = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let openDelay = Duration.milliseconds(900)
    static let grace = Duration.milliseconds(300)
    /// How long after a card closes the next row opens at once.
    static let warm: TimeInterval = 1

    private init() {}

    func enterRow(_ r: Request, anchor: AnchorBox) {
        overRow = r.session.id
        closing?.cancel()
        if current?.session.id == r.session.id { return }
        opening?.cancel()
        if current != nil || Date().timeIntervalSince(closedAt) < Self.warm {
            show(r, anchor: anchor)
            return
        }
        opening = Task {
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled, overRow == r.session.id else { return }
            show(r, anchor: anchor)
        }
    }

    func leaveRow(_ id: String) {
        if overRow == id { overRow = nil }
        opening?.cancel()
        scheduleClose()
    }

    func enterCard() {
        overCard = true
        closing?.cancel()
    }

    func leaveCard() {
        overCard = false
        scheduleClose()
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
        overCard = false
        closedAt = Date()
    }

    private func scheduleClose() {
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: Self.grace)
            guard !Task.isCancelled, !overCard, overRow == nil else { return }
            close()
        }
    }

    private func show(_ r: Request, anchor box: AnchorBox) {
        // The git badge's card owns the moment while it's up.
        guard GitCardController.shared.current == nil else { return }
        guard let rect = box.screenRect, let window = box.view?.window else { return }
        current = r
        anchor = box
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        place(panel, beside: rect, on: window.screen)
        panel.orderFront(nil)
        watch(window)
    }

    /// Re-fit the panel after its content grew (git stats arrived).
    func refit() {
        guard let panel, let rect = anchor?.screenRect else { return }
        place(panel, beside: rect, on: panel.screen)
    }

    /// Just past the sidebar's edge, its top level with the row's.
    private func place(_ panel: NSPanel, beside rect: NSRect, on screen: NSScreen?) {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = screen?.visibleFrame ?? .infinite
        var x = rect.maxX + 12
        var y = rect.maxY - size.height + 4
        if x + size.width > visible.maxX - 4 { x = rect.minX - size.width - 12 }
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> CardPanel {
        let p = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: ThreadCardHost())
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        return p
    }

    private func watch(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        let closeIt: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        observers = [
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: closeIt),
            nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: closeIt),
            nc.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: closeIt),
        ]
    }
}

/// The row's view, for placing the card.
struct ThreadAnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

private struct ThreadCardHost: View {
    @State private var controller = ThreadCardController.shared

    var body: some View {
        if let r = controller.current {
            ThreadCard(request: r)
                .id(r.session.id)
                .onHover { inside in
                    inside ? controller.enterCard() : controller.leaveCard()
                }
        }
    }
}

/// The card: title and age, the live line, then where and on what.
private struct ThreadCard: View {
    let request: ThreadCardController.Request
    /// The tree's uncommitted changes, read once when the card opens.
    @State private var git: GitInfo?
    private var session: SessionInfo { request.session }
    private var library: Library { request.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.frog(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 8)
                Text(age).font(.frog(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                if waiting {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
            }
            if let line {
                Text(line)
                    .font(.frog(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.hover, in: .rect(cornerRadius: 8))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if session.isCloud || place != nil {
                    GridRow {
                        label("Where")
                        HStack(spacing: 5) {
                            // The thread's own place: a cloud glyph when it runs in the cloud.
                            if session.isCloud {
                                Image(systemName: "cloud").font(.frog(size: 11)).foregroundStyle(.secondary)
                                    .help("This thread runs in Frog Cloud")
                            }
                            if let place { Text(place).font(.frog(size: 12)).lineLimit(1) }
                        }
                    }
                }
                if !session.model.isEmpty {
                    GridRow {
                        label("Model")
                        // Where the model runs is its dot's color (green cloud, blue local),
                        // never words: "Frog Cloud" beside a cloud thread read as either.
                        let id = ModelIdentity.of(session.model, in: [])
                        HStack(spacing: 5) {
                            Circle().fill(Color.place(id.place)).frame(width: 6, height: 6)
                            Text(id.name).font(.frog(size: 12)).lineLimit(1)
                        }
                        .help(id.place.label)
                    }
                }
                if let spent {
                    GridRow {
                        label("Spent")
                        Text(spent).font(.frog(size: 12)).monospacedDigit().lineLimit(1)
                    }
                }
                if let git, git.changed > 0 {
                    GridRow {
                        label("Changes")
                        HStack(spacing: 6) {
                            Text("+\(git.added)").foregroundStyle(Tokens.placeCloud)
                            Text("−\(git.removed)").foregroundStyle(Tokens.warn)
                            Text("\(git.changed) file\(git.changed == 1 ? "" : "s")").foregroundStyle(.secondary)
                        }
                        .font(.frog(size: 12)).monospacedDigit()
                    }
                }
            }
            if let p = permission {
                // Answer in place: the one decision the card can make without the thread's
                // context. Anything with a preview or a note goes through Open.
                HStack(spacing: 6) {
                    Button("Allow once") {
                        library.conversation(session.id)?.answer(.allow)
                        ThreadCardController.shared.close()
                    }
                    .buttonStyle(.glassProminent)
                    .help(p.arg)
                    Button("Open") {
                        ThreadCardController.shared.close()
                        request.open()
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.small)
            } else if waiting {
                Button("Open to answer") {
                    ThreadCardController.shared.close()
                    request.open()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
        }
        .task(id: session.id) {
            guard !session.isChat, !session.isCloud, let folder = session.folder else { return }
            git = await Git.status(folder)
            ThreadCardController.shared.refit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(8)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.frog(size: 11)).foregroundStyle(.tertiary)
    }

    private var title: String {
        session.title == nil && session.firstInput == nil ? "New session" : session.displayTitle
    }

    private var waiting: Bool { library.live[session.id] == .waiting }

    private var age: String {
        let a = SessionAgeShort.age(session.modifiedDate)
        return a == "now" ? "1m" : a
    }

    /// What it's saying now: the sidebar's own status line (the ask, the step in hand, the end of
    /// its last word), else a word for the live state.
    private var line: String? {
        if let text = library.rowLine(session).text { return text }
        switch library.live[session.id] {
        case .running: return "Working…"
        case .waiting: return "Waiting on you"
        case .unread: return "Finished while you were away"
        case nil: return nil
        }
    }

    /// Tokens and dollars over the loaded thread's turns; nil when it isn't loaded.
    private var spent: String? {
        guard let c = library.conversation(session.id) else { return nil }
        let usages = c.turns.compactMap(\.usage)
        guard !usages.isEmpty else { return nil }
        let tokens = usages.reduce(UInt64(0)) { $0 + $1.inputTokens + $1.outputTokens }
        let costs = usages.compactMap { ModelStats.shared.cost(of: $0, spec: $0.model ?? session.model) }
        let dollars = costs.isEmpty ? nil : Dollars.format(costs.reduce(0, +))
        return ["\(tokens.tokens) tokens", dollars].compactMap { $0 }.joined(separator: ", ")
    }

    /// The open permission ask, when the thread is loaded and waiting on one.
    private var permission: PermissionRequest? { library.conversation(session.id)?.permission }

    /// "frog   gateway-auth": the folder, then the worktree when there is one. Chats, and a
    /// cloud thread with no project of its own, have none (the cloud glyph says where).
    private var place: String? {
        guard !session.isChat, let folder = session.folder else { return nil }
        if session.isCloud && session.cwd == "/Frog Cloud" { return nil }
        let base = folder.lastPathComponent
        if let wt = SessionList.worktreeName(folder) { return "\(base)   \(wt)" }
        return base
    }
}
