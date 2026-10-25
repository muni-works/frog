import AppKit
import SwiftUI

/// The toolbar's center, like Xcode's activity viewer: one glass capsule that says what frog is
/// doing right now (or how the last turn went), with the model readout on the right: the model
/// and generation speed. How full the context is shows by the composer (`ContextButton`).
struct ActivityViewer: View {
    let workspace: Workspace
    let conversation: Conversation
    /// Scroll the conversation to a turn.
    var jump: (TurnState.ID) -> Void = { _ in }
    /// In a split window: the pane's number leads the pill and a close button ends it.
    var pane: PaneBadge? = nil

    struct PaneBadge {
        let number: Int
        let focused: Bool
        let close: () -> Void
    }
    @State private var showActivity = false
    @State private var hovering = false
    @State private var pickingModel = false
    @State private var library = Library.shared
    @AppStorage("playfulFrog") private var playful = true
    @Environment(\.openSession) private var openSession

    /// A permission prompt or a server's question: the pill turns amber and takes you there.
    private var waiting: String? { ActivityLabel.waiting(conversation) }

    /// Other conversations that are running, waiting on you, or finished unseen.
    private var others: [(session: SessionInfo, live: Library.Live)] {
        library.live
            .filter { $0.key != conversation.sessionID }
            .compactMap { id, live in library.sessions.first { $0.id == id }.map { ($0, live) } }
            .sorted { rank($0.live) < rank($1.live) }
    }

    private func rank(_ l: Library.Live) -> Int {
        switch l { case .waiting: 0; case .running: 1; case .unread: 2 }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let pane {
                Text("\(pane.number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(pane.focused ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 20)
                    .background(pane.focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
                    .padding(.leading, -6)
            }
            if let waiting {
                Button {
                    if let last = conversation.turns.last { jump(last.id) }
                } label: {
                    HStack(spacing: 7) {
                        icon(.waiting) { Image(systemName: "hand.raised.fill") }
                        Text(waiting).fontWeight(.medium).lineLimit(1)
                        Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.orange)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show the request")
            } else {
                Button { showActivity.toggle() } label: {
                    activity.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Activity")
                .popover(isPresented: $showActivity, arrowEdge: .bottom) {
                    ActivityPanel(conversation: conversation) { id in
                        showActivity = false
                        jump(id)
                    }
                }
                if conversation.busy, hovering {
                    Button { conversation.interrupt() } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.secondary)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("Interrupt (Esc or ⌘.)")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            if let s = conversation.status {
                Divider().frame(height: 14)
                readout(s)
            }
            if !others.isEmpty {
                Divider().frame(height: 14)
                othersMenu
            }
            if let pane, hovering {
                Button(action: pane.close) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
                .help("Close pane (⌃⌘W)")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        // Hugs its content: a short state reads as a small pill, not a mostly empty bar.
        .fixedSize()
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            if conversation.busy, waiting == nil { WorkingLine().padding(.horizontal, 16) }
        }
        .glassEffect(tint, in: .capsule)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: conversation.busy)
        .animation(.snappy(duration: 0.2), value: waiting)
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: others.count)
    }

    /// The frog in the pill, or the plain symbol when the playful frog is off.
    @ViewBuilder
    private func icon(_ mood: FrogMood, @ViewBuilder plain: () -> some View) -> some View {
        if playful {
            FrogFace(mood: mood, size: 16).frame(width: 16)
        } else {
            plain().frame(width: 14)
        }
    }

    private var tint: Glass {
        if conversation.failure != nil { return .regular.tint(.red.opacity(0.18)) }
        if waiting != nil { return .regular.tint(.orange.opacity(0.18)) }
        return .regular
    }

    /// A dot per state and a count; the menu opens any of them.
    private var othersMenu: some View {
        let list = others
        let color: Color = list.contains { $0.live == .waiting } ? .orange : list.contains { $0.live == .running } ? .blue : .secondary
        return Menu {
            ForEach(list, id: \.session.id) { entry in
                Button {
                    openSession?(entry.session)
                } label: {
                    Label(entry.session.displayTitle, systemImage: symbol(entry.live))
                    Text(caption(entry.live))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("\(list.count)").monospacedDigit()
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpForOthers(list))
    }

    private func symbol(_ l: Library.Live) -> String {
        switch l { case .waiting: "hand.raised.fill"; case .running: "circle.dotted"; case .unread: "circle.fill" }
    }

    private func caption(_ l: Library.Live) -> String {
        switch l { case .waiting: "Waiting on you"; case .running: "Working"; case .unread: "Finished" }
    }

    private func helpForOthers(_ list: [(session: SessionInfo, live: Library.Live)]) -> String {
        let n = { (l: Library.Live) in list.filter { $0.live == l }.count }
        return [(n(.waiting), "waiting on you"), (n(.running), "working"), (n(.unread), "finished")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
            .joined(separator: " · ") + " in other conversations"
    }

    // MARK: Left: what's happening

    private var activity: some View {
        ActivityLabel(conversation: conversation, playful: playful)
    }

    // MARK: Right: the readout

    /// The model, and what this conversation has cost if it ran on priced models.
    private func readoutHelp(_ s: Status) -> String {
        let spent = conversation.turns.compactMap { $0.usage.flatMap { ModelStats.shared.cost(of: $0) } }.reduce(0, +)
        let spoken = workspace.identity(s.model).spoken
        var totals: [String] = []
        if spent > 0 { totals.append(ModelStats.money(spent)) }
        // The conversation's energy, tucked in here rather than on screen.
        let energy = conversation.turns.compactMap { $0.usage?.energy }
        if UserDefaults.standard.bool(forKey: ModelStats.energyKey), !energy.isEmpty {
            totals.append(ModelStats.energy(energy.map(\.totalWh).reduce(0, +), estimated: energy.contains(where: \.estimated)))
        }
        return totals.isEmpty ? spoken : "\(spoken). This conversation: \(totals.joined(separator: ", "))"
    }

    private func readout(_ s: Status) -> some View {
        HStack(spacing: 8) {
            Button { pickingModel.toggle() } label: {
                ModelLabel(model: workspace.identity(s.model))
                    .fontWeight(.medium)
                    .hoverPlate(h: 4, v: 2)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -2)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(conversation.busy)
            .help(readoutHelp(s))
            .popover(isPresented: $pickingModel, arrowEdge: .bottom) {
                ModelMenu(workspace: workspace, current: s.model) { spec in
                    workspace.use(spec)
                    pickingModel = false
                } close: {
                    pickingModel = false
                }
            }
            if let tps = s.tokensPerSec, tps > 0 {
                Text(ModelStats.speedText(tps * ModelStats.wordsPerToken))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let degraded = s.degraded, !degraded.isEmpty {
                DegradedBadge(degraded: degraded)
            }
        }
    }
}

/// A small warm badge for a session running degraded: what (text tool calls, a model nobody
/// picked, auto mode on fallback) in the pill, each one's why on hover and a click away.
struct DegradedBadge: View {
    let degraded: [Degraded]
    @State private var open = false

    var body: some View {
        if let label = Degraded.badge(degraded) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
                    Text(label).lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.14), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(Degraded.detail(degraded))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(degraded, id: \.kind) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.what).font(.callout.weight(.semibold))
                            Text(d.why).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(width: 300, alignment: .leading)
            }
        }
    }
}

/// Dock tile progress, like Xcode's: while any window has a turn running, the icon gets a
/// spinning ring; it goes away when everything is idle.
@MainActor
final class DockActivity {
    static let shared = DockActivity()

    private var busy: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private var phase: CGFloat = 0
    private lazy var view = DockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))

    func set(_ id: ObjectIdentifier, busy isBusy: Bool) {
        if isBusy { busy.insert(id) } else { busy.remove(id) }
        update()
    }

    private func update() {
        if busy.isEmpty {
            timer?.invalidate()
            timer = nil
            NSApp.dockTile.contentView = nil
            NSApp.dockTile.display()
            return
        }
        guard timer == nil else { return }
        NSApp.dockTile.contentView = view
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.phase = (self.phase + 1 / 24).truncatingRemainder(dividingBy: 1)
                self.view.phase = self.phase
                NSApp.dockTile.display()
            }
        }
    }
}

private final class DockTileView: NSView {
    var phase: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.insetBy(dx: 10, dy: 10)
        let center = NSPoint(x: inset.midX, y: inset.midY)
        let radius = inset.width / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.black.withAlphaComponent(0.25).setStroke()
        track.lineWidth = 7
        track.stroke()
        let arc = NSBezierPath()
        let start = 90 - phase * 360
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - 100, clockwise: true)
        (NSColor(named: "AccentColor") ?? .systemGreen).setStroke()
        arc.lineWidth = 7
        arc.lineCapStyle = .round
        arc.stroke()
    }
}
