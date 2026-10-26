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

/// The Dock tile while any window has a turn running: the icon's frog, working (its throat
/// pumps), instead of a spinner; the plain icon when everything is idle.
@MainActor
final class DockActivity {
    static let shared = DockActivity()

    private var busy: Set<ObjectIdentifier> = []
    private var timer: Timer?
    private lazy var view = NSHostingView(rootView: DockFrog(at: .now))

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
        view.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        NSApp.dockTile.contentView = view
        // The Dock takes a snapshot per display(): at the frog's own 30 a second, as in the app.
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.view.rootView = DockFrog(at: .now)
                NSApp.dockTile.display()
            }
        }
    }
}

/// The app icon redrawn live: its dark squircle (AppIcon.icon's fill, on the macOS icon grid)
/// and the frog in it, posed at `at`.
private struct DockFrog: View {
    let at: Date

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width * 0.8125
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.090, green: 0.102, blue: 0.094),
                                                  Color(red: 0.059, green: 0.067, blue: 0.059)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.35), radius: geo.size.width * 0.02, y: geo.size.width * 0.01)
                FrogFace(mood: .working, size: side * 0.78, at: at)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
