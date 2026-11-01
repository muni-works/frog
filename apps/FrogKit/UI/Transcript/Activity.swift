import SwiftUI

/// What frog is doing right now, or how the last turn went: "Reading main.rs 12s", "Done in 3s",
/// "Interrupted". The Mac's activity viewer leads with it; the phone's chat title shows it.
struct ActivityLabel: View {
    let conversation: Conversation
    /// Playful words ("Hopping to it", "Caught it") or plain ones (Settings › Appearance on the
    /// Mac). The icon is a plain symbol either way.
    var playful = true
    var maxWidth: CGFloat = 300

    var body: some View {
        #if DEBUG
        let _ = PillProbe.label()
        #endif
        if conversation.failure != nil {
            HStack(spacing: 7) {
                icon { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red) }
                Text(playful ? "Croak. Engine stopped" : "Engine stopped").fontWeight(.medium)
            }
        } else if conversation.replaying {
            // Only seen when opening is slow (a quick open shows the finished state straight away).
            HStack(spacing: 7) {
                icon { Image(systemName: "hourglass").foregroundStyle(.secondary) }
                Text("Opening…").foregroundStyle(.secondary)
            }
        } else if conversation.busy, let turn = conversation.turns.last, !turn.finished {
            // No clock here: the app keeps exactly one, the live status row in the transcript.
            // The words change when the work does, so the label has nothing to tick for.
            HStack(spacing: 7) {
                icon { Image(systemName: Self.symbol(turn)).foregroundStyle(.tint) }
                // Hugs the text, up to `maxWidth`.
                Text(Self.live(turn, in: conversation)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else if conversation.busy {
            HStack(spacing: 7) {
                icon { Image(systemName: "hourglass").foregroundStyle(.secondary) }
                Text(conversation.progress.map { $0.label.prefix(1).uppercased() + $0.label.dropFirst() } ?? (playful ? "Hopping to it" : "Starting…"))
                    .lineLimit(1)
            }
        } else if let turn = conversation.turns.last, let end = turn.end {
            HStack(spacing: 7) {
                icon { Image(systemName: Self.done(end).symbol).foregroundStyle(Self.done(end).color) }
                if case .complete = end, let d = Self.duration(turn) {
                    Text(playful && conversation.justFinished ? "Caught it" : "Done in \(d)").monospacedDigit()
                } else {
                    Text(Self.done(end).text).lineLimit(1)
                    if let d = Self.duration(turn) {
                        Text(d).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } else {
            HStack(spacing: 7) {
                icon { Image(systemName: "circle.fill").font(.frog(size: 7)).foregroundStyle(.green) }
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }

    /// The state's plain symbol. The frog's face is retired from the live chrome (it stays on
    /// the empty page and decorative spots); `playful` now only flavors the words.
    private func icon(@ViewBuilder plain: () -> some View) -> some View {
        plain().frame(width: 14)
    }

    /// A permission prompt or a server's question, in a few words.
    static func waiting(_ c: Conversation) -> String? {
        if let p = c.permission { return "Needs approval: \(ToolIcon.title(p.name))" }
        if c.elicitation != nil { return "Waiting for your answer" }
        return nil
    }

    static func symbol(_ turn: TurnState) -> String {
        guard let last = turn.items.last else { return "sparkles" }
        switch last.kind {
        case .tool(let name, _): return ToolIcon.symbol(name)
        case .reasoning: return "sparkles"
        case .message: return "text.bubble"
        case .notice: return "info.circle"
        }
    }

    static func live(_ turn: TurnState, in c: Conversation) -> String {
        if c.permission != nil { return "Waiting for your permission" }
        guard let last = turn.items.last else { return "Thinking" }
        // A Task in hand: the agents say what they're doing in the sidebar; here, how many.
        if let waiting = c.waitingOnAgents(turn) { return waiting }
        switch last.kind {
        case .tool(let name, let arg):
            let verb = ["Bash": "Running", "Read": "Reading", "Edit": "Editing", "Write": "Writing",
                        "Grep": "Searching", "Glob": "Finding", "Diagram": "Drawing", "CodeMap": "Mapping",
                        "Present": "Laying out", "Ask": "Asking",
                        "Task": "Delegating", "McpTools": "Finding tools", "Skill": "Loading skill",
                        "WebFetch": "Fetching", "WebSearch": "Searching the web", "Docs": "Reading docs"][name]
                ?? ToolIcon.title(name)
            return arg.isEmpty ? verb : "\(verb) \(arg)"
        case .reasoning: return "Thinking"
        case .message: return "Writing the answer"
        case .notice: return last.text
        }
    }

    /// "12s", "3m 4s": a finished turn, start to end.
    static func duration(_ turn: TurnState) -> String? {
        guard let a = turn.startedAt, let b = turn.endedAt else { return nil }
        return clock(Int(b.timeIntervalSince(a)))
    }

    private static func clock(_ s: Int) -> String { s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s" }

    static func done(_ end: EndReason) -> (text: String, symbol: String, color: Color) {
        switch end {
        case .complete: ("Finished", "checkmark.circle.fill", .green)
        case .denied: ("Stopped: permission denied", "hand.raised.fill", .orange)
        case .blockedOnApproval: ("Stopped: retried a denied call", "hand.raised.fill", .orange)
        case .cancelled: ("Interrupted", "stop.circle.fill", .secondary)
        case .suspended: ("Suspended for app update", "pause.circle.fill", .secondary)
        case .maxTokens(let autoContinued): (
            autoContinued == 0 ? "Hit the output limit" : "Hit the output limit (\(autoContinued)x)",
            "text.append",
            .orange
        )
        case .looping: ("Stopped: repeating itself", "arrow.trianglehead.2.clockwise", .orange)
        case .stepLimit: ("Stopped at the step limit", "flag.checkered", .orange)
        case .error: ("Failed", "exclamationmark.octagon.fill", .red)
        }
    }
}

/// What the latest turn did, live: its steps and how each went, time, calls and tokens, and
/// anything queued. Stop it, or jump to it in the conversation.
struct ActivityPanel: View {
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
        .foregroundStyle(.primary)
    }

    private func header(_ turn: TurnState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.number.map { "Turn \($0)" } ?? "This turn").font(.headline)
                Spacer()
                // How long it took, once it's done; a running turn's clock is the transcript's.
                if let d = ActivityLabel.duration(turn) {
                    Text(d).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
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
        if let tps = u.tokensPerSec, tps > 0 { parts.append(ModelStats.speedText(tps)) }
        if let c = ModelStats.shared.cost(of: u) { parts.append(ModelStats.money(c)) }
        if UserDefaults.standard.bool(forKey: ModelStats.energyKey), let e = u.energy {
            parts.append(ModelStats.energy(e.totalWh, estimated: e.estimated))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
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

/// An indeterminate progress sweep along the bottom edge of what's working.
struct WorkingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if DEBUG
        let _ = PillProbe.line()
        #endif
        // The sweep rides a 1Hz beat, not its own 60/s timeline: the motion is 1.6s long, so
        // one step a second is indistinguishable at this height and the churn mostly leaves.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            #if DEBUG
            let _ = PillProbe.line()
            #endif
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
