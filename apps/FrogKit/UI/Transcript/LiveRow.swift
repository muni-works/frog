import SwiftUI

// The thinking row and the stats line (docs/design/transcript/spec.md, phase 2; boards 2, 3
// and 5, set to boards 9 and 8). One row while Frog works: a dot, a label, and the engine's
// thought or the step's object, with the turn's stats two points under it. Thinking cross-fades;
// everything else cuts. The row is a button that opens the thinking as an outline.

/// What the live row says, worked out once from the turn (pure, so it's tested).
struct LiveState: Equatable {
    enum Dot: Equatable {
        /// Tokens are arriving: it breathes.
        case live
        /// Working, nothing arriving: held still.
        case still
        /// No output for a while: still and grey.
        case stalled
        /// Waiting on a person: amber, still.
        case you
    }

    var dot: Dot
    /// "Thinking", "Running", "Waiting for you".
    var label: String
    /// The thought (muted, cross-fades) or the step's object (fg, cuts); "" for none.
    var detail: String
    /// The detail is a thought: muted, and it cross-fades.
    var thought: Bool
    /// The detail is a command, path or pattern.
    var mono: Bool
    /// "No output for 12s", in place of the thought.
    var quiet: String
    /// At 30 s without output: offer Stop.
    var offersStop: Bool
    /// The reasoning item the row opens, when it's thinking.
    var reasoningID: String?

    /// How long without a token before the row says so, and before it offers Stop.
    static let stallAfter: TimeInterval = 10
    static let stopAfter: TimeInterval = 30
    /// A think's first moments show no thought, even if one arrives.
    static let quietStart: TimeInterval = 0.6

    /// The row for a running turn at `now`; nil when there's no row (the answer is writing:
    /// only the stats show, under the text).
    static func of(_ turn: TurnState, waiting: String?, lastToken: Date?, now: Date) -> LiveState? {
        if let waiting {
            return LiveState(dot: .you, label: "Waiting for you", detail: waiting, thought: false, mono: false,
                             quiet: "", offersStop: false, reasoningID: nil)
        }
        let running = turn.items.filter { !$0.done }
        if let last = turn.items.last, last.kind == .message, !last.done,
           !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let tools = running.filter { if case .tool = $0.kind { true } else { false } }
        if let step = tools.last, let line = StepLine.of(step) {
            // Several at once fold into a count ("Reading 3 files").
            let same = tools.filter { if case .tool(let n, _) = $0.kind { Verbs.look(n).live == line.verb } else { false } }
            let detail = same.count > 1 ? "\(same.count) \(Self.noun(Verbs.look(line.name).object, same.count))" : line.object
            return LiveState(dot: .still, label: line.verb, detail: detail, thought: false,
                             mono: same.count > 1 ? false : line.mono, quiet: "", offersStop: false, reasoningID: nil)
        }
        let think = running.last { $0.kind == .reasoning }
        let since = lastToken ?? think?.startedAt ?? turn.startedAt
        let silent = since.map { now.timeIntervalSince($0) } ?? 0
        var state = LiveState(dot: .still, label: "Thinking", detail: "", thought: true, mono: false,
                              quiet: "", offersStop: false, reasoningID: think?.id)
        if let lastToken, now.timeIntervalSince(lastToken) < 1.5 { state.dot = .live }
        if let think, let line = think.thought,
           now.timeIntervalSince(think.startedAt ?? .distantPast) >= quietStart {
            state.detail = line
        }
        if silent >= stallAfter {
            state.dot = .stalled
            state.quiet = "No output for \(Int(silent))s"
            state.detail = ""
            state.offersStop = silent >= stopAfter
        }
        return state
    }

    private static func noun(_ object: Verbs.Object, _ n: Int) -> String {
        switch object {
        case .path: "files"
        case .command: "commands"
        case .host: "pages"
        default: "steps"
        }
    }
}

/// The stats under the live row (or under the answer while it writes): time, tokens, tokens per
/// second, in `meta`. Time shows after the first second; tokens once any are counted.
struct LiveStats: Equatable {
    var elapsed: TimeInterval
    var tokens: UInt64?
    /// The token figure is a count of what has arrived: never shown as exact.
    var soFar: Bool
    var perSecond: Double?
    /// Under a quarter of the model's usual rate for 5 s.
    var slow: Bool
    /// How long it has waited on you, while a card is up.
    var waited: TimeInterval? = nil

    var parts: [String] {
        var out: [String] = []
        if elapsed >= 1 { out.append(Self.clock(elapsed)) }
        if let tokens, tokens > 0, waited == nil { out.append("\(tokens.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) tokens") }
        if let waited {
            // Waiting on you: the clock and how long it has waited; the speed means nothing now.
            out.append("waited \(Self.clock(max(0, waited)))")
            return out
        }
        if let perSecond, perSecond > 0 {
            out.append("\(Int(perSecond.rounded())) tok/s" + (slow ? ", slower than usual" : ""))
        }
        return out
    }

    var text: String { parts.joined(separator: " · ") }

    /// "19s", "2m 5s": whole seconds, for a clock that ticks.
    static func clock(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    /// The stats spelled out, for the hover.
    var help: String {
        var lines: [String] = []
        if elapsed >= 1 { lines.append("Working for \(Int(elapsed.rounded())) seconds") }
        if let tokens, tokens > 0 {
            let rate = perSecond.map { " at \(Int($0.rounded())) tokens per second" } ?? ""
            lines.append("Written \(tokens.formatted()) tokens\(soFar ? " so far" : "")\(rate)")
        }
        return lines.joined(separator: "\n")
    }

    /// The figures for a running turn at `now`.
    static func of(_ turn: TurnState, pulse: LivePulse, usual: Double?, now: Date) -> LiveStats {
        let elapsed = turn.startedAt.map { now.timeIntervalSince($0) } ?? 0
        var rate: Double?
        if let tokens = pulse.output, let first = pulse.firstTokenAt {
            let writing = now.timeIntervalSince(first)
            if writing >= 1 { rate = Double(tokens) / writing }
        }
        let slow: Bool = {
            guard let rate, let usual, usual > 0, let first = pulse.firstTokenAt, now.timeIntervalSince(first) >= 5 else { return false }
            return rate < usual / 4
        }()
        return LiveStats(elapsed: elapsed, tokens: pulse.output, soFar: pulse.soFar, perSecond: rate, slow: slow)
    }
}

// MARK: - The row

/// The live row: dot, label, thought or object, the stats under it. Ticks once a second (the
/// clock and the stall), and with the turn's pulse.
struct LiveRow: View {
    let turn: TurnState
    let conversation: Conversation
    @State private var open = false
    @State private var hovered = false
    @State private var keptWaiting: Date?
    @Environment(\.transcriptEdge) private var edge
    @Environment(\.turnSpace) private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var waiting: String? {
        if let p = conversation.permission { return p.question }
        if conversation.elicitation != nil { return "Waiting for your answer" }
        return nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pulse = conversation.pulse
            let state = LiveState.of(turn, waiting: waiting, lastToken: pulse.lastTokenAt, now: ctx.date)
            let stats = stats(at: ctx.date)
            VStack(alignment: .leading, spacing: space.gaps.stats) {
                if let state { row(state, at: ctx.date) }
                if !stats.text.isEmpty || state != nil {
                    StatsLine(stats: stats)
                }
                if open, let id = state?.reasoningID, let think = turn.items.first(where: { $0.id == id }) {
                    ThinkingOutline(item: think, live: true)
                        .padding(.leading, edge.indent)
                        .padding(.top, TurnSpace.Inset.tight)
                }
            }
        }
    }

    private func stats(at now: Date) -> LiveStats {
        var stats = LiveStats.of(turn, pulse: conversation.pulse,
                                 usual: conversation.status.flatMap { ModelStats.shared.speed($0.model) }, now: now)
        if waiting != nil { stats.waited = conversation.permissionAt.map { now.timeIntervalSince($0) } }
        return stats
    }

    private func row(_ state: LiveState, at now: Date) -> some View {
        Button {
            guard state.reasoningID != nil else { return }
            withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
            LineFrame(hovered: hovered && state.reasoningID != nil) {
                LiveDot(dot: state.dot)
            } content: {
                Text(state.label).font(.frog(size: Tokens.Transcript.status.size))
                    .foregroundStyle(state.dot == .you ? Tokens.notice : Tokens.text)
                    .fixedSize()
                    .metricsFirstWord()
                if hovered, state.reasoningID != nil {
                    Image(systemName: "chevron.right").font(.frog(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                detail(state)
                Spacer(minLength: 0)
                if state.offersStop, keptWaiting.map({ now.timeIntervalSince($0) >= LiveState.stopAfter }) ?? true {
                    Button("Keep waiting") { keptWaiting = now }
                        .buttonStyle(.plain).font(.frog(size: Tokens.Transcript.meta.size))
                        .foregroundStyle(Tokens.textSecondary)
                    Button("Stop") { conversation.interrupt() }
                        .buttonStyle(CardButtonStyle())
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(state.reasoningID != nil)
        .onHover { hovered = $0 }
        .metricsRow(.live, [state.label, open ? "" : (state.quiet.isEmpty ? state.detail : state.quiet)].filter { !$0.isEmpty }.joined(separator: " "),
                    key: "live-\(turn.id)", fontSize: Tokens.Transcript.status.size)
    }

    @ViewBuilder
    private func detail(_ state: LiveState) -> some View {
        if !state.quiet.isEmpty {
            Text(state.quiet).font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                .monospacedDigit().lineLimit(1)
        } else if state.thought {
            // The row's own thought hides while the outline shows it.
            ZStack(alignment: .leading) {
                if !open, !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(state.detail)
                        .id(state.detail)
                        .transition(reduceMotion ? .identity : .asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.24)),
                            removal: .opacity.animation(.easeIn(duration: 0.18))))
                }
            }
            .animation(reduceMotion ? nil : .default, value: state.detail)
        } else if !state.detail.isEmpty {
            Text(state.detail)
                .font(state.mono ? .frog(size: Tokens.Transcript.status.mono, design: .monospaced) : .frog(size: Tokens.Transcript.status.size))
                .foregroundStyle(Tokens.text)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// The live dot, in the row's mark box: green and breathing while tokens arrive, still between
/// them, grey when stalled, amber only when it's waiting on you.
struct LiveDot: View {
    let dot: LiveState.Dot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let breathing = dot == .live && !reduceMotion
        TimelineView(.animation(paused: !breathing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(dot == .you ? Tokens.notice : dot == .stalled ? Tokens.textTertiary : Tokens.accent)
                .frame(width: 6, height: 6)
                .opacity(breathing ? 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.6)) : 1)
        }
        .frame(width: 6, height: 6)
    }
}

/// Time, tokens and speed in `meta`, the hover spelling them out.
struct StatsLine: View {
    let stats: LiveStats
    @Environment(\.transcriptEdge) private var edge

    var body: some View {
        Text(stats.text.isEmpty ? " " : stats.text)
            .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
            .foregroundStyle(Tokens.textTertiary)
            .frame(height: Tokens.Transcript.meta.line, alignment: .leading)
            .help(stats.help)
            .padding(.leading, edge.indent)
            .metricsFirstWord()
            .metricsRow(.stats, stats.text, key: "stats", fontSize: Tokens.Transcript.meta.size)
    }
}

// MARK: - The outline

/// A think opened (board 5): one line per thought it showed, newest in `fg` while live. A click
/// on a line opens that paragraph as written; past twelve lines, "N more" opens the whole text
/// in its own scrolling box. Return opens, arrows move, Esc closes one level.
struct ThinkingOutline: View {
    let item: ItemState
    var live = false
    static let cap = 12
    @State private var openLine: Int?
    @State private var all = false
    @FocusState private var focused: Int?

    struct Line: Equatable {
        var text: String
        var paragraph: String
    }

    var body: some View {
        let lines = Self.lines(item)
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                // An old log (or a think that never showed a line): the text itself, capped.
                CappedThought(text: item.text)
            } else {
                ForEach(Array(lines.prefix(Self.cap).enumerated()), id: \.offset) { i, line in
                    let newest = live && i == lines.count - 1
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { openLine = openLine == i ? nil : i }
                        } label: {
                            Text(line.text)
                                .font(.frog(size: Tokens.Transcript.status.size))
                                .foregroundStyle(newest ? Tokens.text : Tokens.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, minHeight: Tokens.Transcript.status.line, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focused, equals: i)
                        .help(line.text)
                        if openLine == i {
                            Text(line.paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.frog(size: Tokens.Transcript.status.size))
                                .foregroundStyle(Tokens.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, TurnSpace.Inset.roomy)
                                .padding(.vertical, TurnSpace.Inset.tight)
                                .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
                        }
                    }
                }
                if lines.count > Self.cap {
                    Button(all ? "Show less" : "\(lines.count - Self.cap) more") { withAnimation(.snappy(duration: 0.2)) { all.toggle() } }
                        .buttonStyle(.plain)
                        .font(.frog(size: Tokens.Transcript.meta.size))
                        .foregroundStyle(Tokens.textSecondary)
                        .frame(height: Tokens.Transcript.status.line)
                    if all {
                        ScrollView {
                            Text(item.text).font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 320)
                    }
                }
            }
        }
        .onKeyPress(.downArrow) { move(1, of: min(lines.count, Self.cap)) }
        .onKeyPress(.upArrow) { move(-1, of: min(lines.count, Self.cap)) }
        .onKeyPress(.return) {
            guard let f = focused else { return .ignored }
            openLine = openLine == f ? nil : f
            return .handled
        }
        .onKeyPress(.escape) {
            guard openLine != nil else { return .ignored }
            openLine = nil
            return .handled
        }
    }

    private func move(_ by: Int, of count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        focused = max(0, min(count - 1, (focused ?? -1) + by))
        return .handled
    }

    /// The outline's lines: the engine's list when the think finished (each with its paragraph,
    /// by its UTF-16 range), else the lines shown so far, each matched to the paragraph it came
    /// from.
    static func lines(_ item: ItemState) -> [Line] {
        let text = item.text
        if !item.thoughts.isEmpty {
            let utf16 = text.utf16
            return item.thoughts.map { t in
                let a = utf16.index(utf16.startIndex, offsetBy: max(0, min(t.start, utf16.count)))
                let b = utf16.index(utf16.startIndex, offsetBy: max(0, min(t.end, utf16.count)))
                let paragraph = a < b ? String(utf16[a..<b]) ?? t.text : t.text
                return Line(text: t.text, paragraph: paragraph)
            }
        }
        return item.shownThoughts.map { Line(text: $0.text, paragraph: paragraph(of: $0.text, in: text)) }
    }

    /// The paragraph a live thought line came from: the last finished paragraph containing its
    /// first words (the engine trims lead-ins and markdown, so match on a prefix).
    static func paragraph(of line: String, in text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        let key = String(line.prefix(24)).lowercased()
        return paragraphs.last { $0.lowercased().contains(key) } ?? line
    }
}
