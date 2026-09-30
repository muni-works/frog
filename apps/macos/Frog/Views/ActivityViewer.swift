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
    /// The turn just ended: the frog hops and the pill says "Caught it" for a moment.
    @State private var caught = false
    @AppStorage("playfulFrog") private var playful = true
    @Environment(\.openSession) private var openSession

    /// A permission prompt or a server's question: the pill turns amber and takes you there.
    private var waiting: String? {
        if let p = conversation.permission { return "Needs approval: \(ToolIcon.title(p.name))" }
        if conversation.elicitation != nil { return "Waiting for your answer" }
        return nil
    }

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
        .onChange(of: conversation.turns.last?.endedAt) { _, end in
            guard playful, let end, Date.now.timeIntervalSince(end) < 3 else { return }
            caught = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                caught = false
            }
        }
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

    /// What the frog is doing, from the conversation's state.
    private func mood(_ turn: TurnState?) -> FrogMood {
        if conversation.failure != nil { return .sad }
        if waiting != nil { return .waiting }
        if conversation.busy, let turn, !turn.finished {
            switch turn.items.last?.kind {
            case .tool(let name, _) where ["Read", "Grep", "Glob", "WebFetch", "Docs"].contains(name): return .reading
            case .reasoning, nil: return .thinking
            default: return .working
            }
        }
        if conversation.busy { return .working }
        return caught ? .done : .idle
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

    @ViewBuilder
    private var activity: some View {
        if conversation.failure != nil {
            HStack(spacing: 7) {
                icon(.sad) { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                Text(playful ? "Croak. Engine stopped" : "Engine stopped").fontWeight(.medium)
            }
        } else if conversation.replaying {
            // Only seen when opening is slow (a quick open shows the finished state straight away).
            HStack(spacing: 7) {
                icon(.idle) { Image(systemName: "hourglass").foregroundStyle(.secondary) }
                Text("Opening…").foregroundStyle(.secondary)
            }
        } else if conversation.busy, let turn = conversation.turns.last, !turn.finished {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 7) {
                    icon(mood(turn)) { Image(systemName: symbol(turn)).foregroundStyle(.tint) }
                    Text(live(turn)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 300, alignment: .leading)
                    Text(elapsed(turn)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } else if conversation.busy {
            HStack(spacing: 7) {
                icon(.working) { Image(systemName: "hourglass").foregroundStyle(.secondary) }
                Text(conversation.progress.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? (playful ? "Hopping to it" : "Starting…"))
                    .lineLimit(1)
            }
        } else if let turn = conversation.turns.last, let end = turn.end {
            HStack(spacing: 7) {
                icon(mood(turn)) { Image(systemName: done(end).symbol).foregroundStyle(done(end).color) }
                if case .complete = end, let d = duration(turn) {
                    Text(caught ? "Caught it" : "Done in \(d)").monospacedDigit()
                } else {
                    Text(done(end).text).lineLimit(1)
                    if let d = duration(turn) {
                        Text(d).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } else {
            HStack(spacing: 7) {
                icon(.idle) { Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green) }
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(_ turn: TurnState) -> String {
        guard let last = turn.items.last else { return "sparkles" }
        switch last.kind {
        case .tool(let name, _): return ToolIcon.symbol(name)
        case .reasoning: return "sparkles"
        case .message: return "text.bubble"
        case .notice: return "info.circle"
        }
    }

    private func live(_ turn: TurnState) -> String {
        if conversation.permission != nil { return "Waiting for your permission" }
        guard let last = turn.items.last else { return "Thinking" }
        switch last.kind {
        case .tool("Task", _):
            return "Subagent: \(last.subagent?.activity ?? "Starting")"
        case .tool(let name, let arg):
            let verb = ["Bash": "Running", "Read": "Reading", "Edit": "Editing", "Write": "Writing",
                        "Grep": "Searching", "Glob": "Finding", "Diagram": "Drawing", "CodeMap": "Mapping",
                        "Task": "Delegating", "McpTools": "Finding tools", "Skill": "Loading skill",
                        "WebFetch": "Fetching", "WebSearch": "Searching the web", "Docs": "Reading docs"][name]
                ?? ToolIcon.title(name)
            return arg.isEmpty ? verb : "\(verb) \(arg)"
        case .reasoning: return "Thinking"
        case .message: return "Writing the answer"
        case .notice: return last.text
        }
    }

    private func elapsed(_ turn: TurnState) -> String {
        guard let start = turn.startedAt else { return "" }
        let s = Int(Date.now.timeIntervalSince(start))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func duration(_ turn: TurnState) -> String? {
        guard let a = turn.startedAt, let b = turn.endedAt else { return nil }
        let s = Int(b.timeIntervalSince(a))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func done(_ end: EndReason) -> (text: String, symbol: String, color: Color) {
        switch end {
        case .complete: ("Finished", "checkmark.circle.fill", .green)
        case .denied: ("Stopped: permission denied", "hand.raised.fill", .orange)
        case .cancelled: ("Interrupted", "stop.circle.fill", .secondary)
        case .maxTokens: ("Hit the output limit", "text.append", .orange)
        case .looping: ("Stopped: repeating itself", "arrow.trianglehead.2.clockwise", .orange)
        case .stepLimit: ("Stopped at the step limit", "flag.checkered", .orange)
        case .error: ("Failed", "exclamationmark.octagon.fill", .red)
        }
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
        }
    }
}

/// What the latest turn did, live: its steps and how each went, time, calls and tokens, and
/// anything queued. Stop it, or jump to it in the conversation.
private struct ActivityPanel: View {
    let conversation: Conversation
    let jump: (TurnState.ID) -> Void
    static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = conversation.failure {
                Label(failure, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let turn = conversation.turns.last {
                header(turn)
                steps(turn)
                if let u = turn.usage { stats(u) }
            } else {
                Text("Nothing yet. Send a message and its steps show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !conversation.queue.isEmpty {
                Label("\(conversation.queue.count) message\(conversation.queue.count == 1 ? "" : "s") queued", systemImage: "tray.full")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let turn = conversation.turns.last {
                Divider()
                HStack {
                    if conversation.busy {
                        Button(role: .destructive) { conversation.interrupt() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .help("Interrupt (Esc or ⌘.)")
                    }
                    Spacer()
                    Button("Show in Conversation") { jump(turn.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func header(_ turn: TurnState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.number.map { "Turn \($0)" } ?? "This turn").font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(turn)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if !turn.input.isEmpty {
                Text(turn.request)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func steps(_ turn: TurnState) -> some View {
        let tools = turn.items.filter { if case .tool = $0.kind { true } else { false } }
        if tools.isEmpty {
            Text(turn.finished ? "Answered without tools." : "Thinking…")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if tools.count > Self.shown {
                    Text("\(tools.count - Self.shown) earlier step\(tools.count - Self.shown == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(tools.suffix(Self.shown)) { item in
                    StepRow(item: item)
                }
            }
        }
    }

    private func stats(_ u: TurnUsage) -> some View {
        var parts = ["\(u.modelCalls) call\(u.modelCalls == 1 ? "" : "s")", "\(u.inputTokens.tokens) in", "\(u.outputTokens.tokens) out"]
        if let tps = u.tokensPerSec, tps > 0 { parts.append(ModelStats.speedText(tps * ModelStats.wordsPerToken)) }
        if let c = ModelStats.shared.cost(of: u) { parts.append(ModelStats.money(c)) }
        if UserDefaults.standard.bool(forKey: ModelStats.energyKey), let e = u.energy {
            parts.append(ModelStats.energy(e.totalWh, estimated: e.estimated))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func elapsed(_ turn: TurnState) -> String {
        guard let a = turn.startedAt else { return "" }
        let s = Int((turn.endedAt ?? .now).timeIntervalSince(a))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }
}

private struct StepRow: View {
    let item: ItemState

    var body: some View {
        if case .tool(let name, let arg) = item.kind {
            HStack(spacing: 8) {
                Image(systemName: ToolIcon.symbol(name))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(arg.isEmpty ? ToolIcon.title(name) : "\(ToolIcon.title(name)) \(arg)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                outcome
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var outcome: some View {
        if !item.done {
            ProgressView().controlSize(.mini)
        } else {
            switch item.result?.outcome {
            case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .denied: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            default: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }
}

/// The context ring; click it for how full the context is and to compact it.
struct ContextButton: View {
    let conversation: Conversation
    let status: Status
    @State private var shown = false

    private var fraction: Double {
        guard let used = status.contextTokens, status.contextWindow > 0 else { return 0 }
        return min(1, Double(used) / Double(status.contextWindow))
    }

    var body: some View {
        Button { shown.toggle() } label: {
            ContextRing(status: status).hoverPlate(h: 4, v: 4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Context").font(.headline)
                    Spacer()
                    Text("\(Int(fraction * 100))%").font(.headline.monospacedDigit())
                        .foregroundStyle(fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .primary)
                }
                ProgressView(value: fraction)
                    .tint(fraction > 0.8 ? .red : fraction > 0.6 ? .orange : .accentColor)
                Text("\((status.contextTokens ?? 0).tokens) of \(status.contextWindow.tokens) tokens")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Divider()
                Button {
                    shown = false
                    conversation.compact()
                } label: {
                    Label("Compact Now", systemImage: "arrow.down.right.and.arrow.up.left")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(conversation.busy || conversation.turns.isEmpty)
                Text("Summarizes the conversation so far to free up room (⇧⌘K).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 260)
        }
        .help("Context: \(Int(fraction * 100))% used")
    }
}

/// An indeterminate progress sweep along the bottom edge of the activity viewer.
private struct WorkingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { ctx in
            GeometryReader { geo in
                let w = geo.size.width
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                let x = reduceMotion ? 0 : (t * 1.4 - 0.2) * w
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Color.accentColor.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: reduceMotion ? w : w * 0.3, height: 2)
                    .offset(x: x)
            }
        }
        .frame(height: 2)
        .clipShape(.capsule)
        .allowsHitTesting(false)
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
