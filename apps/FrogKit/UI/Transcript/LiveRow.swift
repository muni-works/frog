import SwiftUI

// The thinking row and the stats line (docs/design/transcript/spec.md, phase 2; boards 2, 3
// and 5, set to boards 9 and 8). One row while Frog works: a dot, a label, and the engine's
// thought or the step's object, with the turn's stats two points under it. Thinking cross-fades;
// everything else cuts. The row is a button that opens the thinking as an outline.

/// What the live row says, worked out once from the turn (pure, so it's tested). The words are
/// verbs.json's `live` entry (`Verbs.Live`); the rules are the web's `liveRow` (rows.ts).
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
    /// "Thinking", "Running", "Reading 3 files", "Waiting for you", "No output for 12s".
    var label: String
    /// The thought (muted, cross-fades) or the step's object (fg, cuts); "" for none.
    var detail: String
    /// The detail is a thought: muted, and it cross-fades.
    var thought: Bool
    /// The detail is a command, path or pattern.
    var mono: Bool
    /// The reasoning item the row opens, when it's thinking.
    var reasoningID: String?

    /// How long without a token before a think says so. At 30 s the engine asks the person (an
    /// ordinary question, "Keep waiting" / "Stop the turn"); the row offers nothing of its own.
    static let stallAfter: TimeInterval = 10
    /// A think's first moments show no thought, even if one arrives.
    static let quietStart: TimeInterval = 0.6

    /// The row for a running turn at `now`; nil when there's no row (the answer is writing:
    /// only the stats show, under the text).
    static func of(_ turn: TurnState, waiting: Bool, lastToken: Date?, now: Date) -> LiveState? {
        func row(_ label: String, _ detail: String = "", mono: Bool = false) -> LiveState {
            LiveState(dot: .still, label: label, detail: detail, thought: false, mono: mono, reasoningID: nil)
        }
        if waiting {
            // The card says what it's waiting for (board 8, C): the row is the label.
            var r = row(Verbs.Live.waiting)
            r.dot = .you
            return r
        }
        let steps = turn.items.filter { item in
            if case .tool = item.kind { !item.done } else { false }
        }
        if steps.count == 1, let line = StepLine.of(steps[0]) {
            return row(line.verb, line.object, mono: line.mono)
        }
        if steps.count > 1, case .tool(let name, _) = steps[0].kind {
            // Several at once fold into a count ("Reading 3 files"), or "Running 3 steps" when
            // they differ.
            let verbs = Set(steps.compactMap { if case .tool(let n, _) = $0.kind { Verbs.look(n).live } else { nil } })
            let look = Verbs.look(name)
            return row(verbs.count == 1 ? "\(look.live) \(steps.count) \(Verbs.Live.counts[look.object] ?? "steps")"
                                        : Verbs.Live.fill(Verbs.Live.mixed, n: steps.count))
        }
        let last = turn.items.last
        if let last, last.kind == .message, !last.done,
           !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let think = last.flatMap { $0.kind == .reasoning && !$0.done ? $0 : nil }
        var state = LiveState(dot: .still, label: Verbs.Live.thinking, detail: "", thought: true, mono: false,
                              reasoningID: think?.id)
        if let lastToken, now.timeIntervalSince(lastToken) < 1.5 { state.dot = .live }
        if let think, let line = think.thought,
           now.timeIntervalSince(think.startedAt ?? .distantPast) >= quietStart {
            state.detail = line
        }
        let since = lastToken ?? think?.startedAt ?? turn.startedAt
        let silent = since.map { now.timeIntervalSince($0) } ?? 0
        if silent >= stallAfter {
            // Stalled is named: the label says how long, and the thought steps aside.
            state.dot = .stalled
            state.label = Verbs.Live.fill(Verbs.Live.stalled, time: LiveStats.clock(silent))
            state.detail = ""
        }
        return state
    }

    /// The row's words as the parity metrics read them: label, object and thought by one space.
    var text: String { [label, detail].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// The stats under the live row (or under the answer while it writes): time, tokens, tokens per
/// second, in `meta` (the web's `Stats`, LiveRow.tsx). Time shows after the first second.
struct LiveStats: Equatable {
    var elapsed: TimeInterval
    var tokens: UInt64?
    /// The token figure is a count of what has arrived: never shown as exact.
    var soFar: Bool
    var perSecond: Int?
    /// The engine says the stream is slow (`output_tokens.slow`).
    var slow: Bool
    /// How long it has waited on you, while a card or question is up.
    var waited: TimeInterval? = nil
    /// An answer writing with nothing arriving for this long (shown from 10 s).
    var quiet: TimeInterval? = nil
    var cached: UInt64? = nil
    var firstToken: TimeInterval? = nil
    var thinking = false

    var parts: [String] {
        var out: [String] = []
        if elapsed >= 1 { out.append(Self.clock(elapsed)) }
        if let waited {
            // Waiting on you: the clock and how long it has waited; the speed means nothing now.
            if waited >= 1 { out.append("waited \(Self.clock(waited))") }
            return out
        }
        if let tokens { out.append("\(Self.grouped(tokens)) tokens") }
        if let perSecond, perSecond > 0 { out.append("\(perSecond) tok/s") }
        if slow { out.append("Slow") }
        if let quiet, quiet >= LiveState.stallAfter {
            out.append(Verbs.Live.fill(Verbs.Live.stalled, time: Self.clock(quiet)).lowercasedFirst)
        }
        return out
    }

    var text: String { parts.joined(separator: ", ") }

    /// "19s", "2m 5s": whole seconds (the web's `secs`).
    static func clock(_ secs: TimeInterval) -> String { StepLine.clock(secs) }

    static func grouped(_ n: UInt64) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// The stats spelled out, for the hover.
    var help: String {
        var lines: [String] = []
        if elapsed >= 1 { lines.append("\(thinking ? "Thinking" : "Working") for \(Self.clock(elapsed).dropLast()) seconds") }
        if waited == nil, let tokens {
            let rate = perSecond.map { " at \($0) tokens per second" } ?? ""
            lines.append("Written \(Self.grouped(tokens)) tokens\(soFar ? " so far" : "")\(rate)")
        }
        if waited == nil, let cached, cached > 0 { lines.append("Read \(Self.grouped(cached)) tokens from cache") }
        if let firstToken { lines.append("First token after \(String(format: "%.1f", max(0, firstToken))) seconds") }
        return lines.joined(separator: "\n")
    }

    /// The figures for a running turn at `now`.
    static func of(_ turn: TurnState, pulse: LivePulse, now: Date) -> LiveStats {
        let elapsed = turn.startedAt.map { now.timeIntervalSince($0) } ?? 0
        var first: TimeInterval?
        if let token = pulse.firstTokenAt, let start = turn.startedAt { first = token.timeIntervalSince(start) }
        return LiveStats(elapsed: elapsed, tokens: pulse.output, soFar: pulse.soFar, perSecond: pulse.rate(at: now),
                         slow: pulse.slow, cached: pulse.cached, firstToken: first)
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - The row

/// The live row: dot, label, thought or object, the stats under it. Ticks once a second (the
/// clock and the stall), and with the turn's pulse.
struct LiveRow: View {
    let turn: TurnState
    let conversation: Conversation
    @State private var open = false
    @State private var hovered = false
    @Environment(\.turnSpace) private var space
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A card or question is up: the row waits on you.
    private var waiting: Bool {
        conversation.permission != nil || conversation.elicitation != nil || conversation.question != nil
    }

    var body: some View {
        if conversation.startCovers(turn), let start = conversation.start {
            // A new cloud session still starting: the same row, saying how far it's got.
            StartRow(start: start)
        } else {
            live
        }
    }

    private var live: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pulse = conversation.pulse
            let state = LiveState.of(turn, waiting: waiting, lastToken: pulse.lastTokenAt, now: ctx.date)
            let stats = stats(at: ctx.date, state)
            if let state {
                VStack(alignment: .leading, spacing: space.gaps.stats) {
                    row(state, at: ctx.date)
                    statsLine(stats, underRow: true)
                    if open, let id = state.reasoningID, let think = turn.items.first(where: { $0.id == id }) {
                        ThinkingOutline(item: think, live: true)
                            .padding(.leading, Tokens.Transcript.Layout.hang)
                            .padding(.top, TurnSpace.Inset.tight)
                    }
                }
            } else {
                // The answer is writing: no row, the stats 2 under its text. Drawn over the fixed
                // space under the last row, so they add no height: the stop at a long answer's
                // start (the scroll code) counts that space and nothing else.
                Color.clear.frame(height: 0)
                    .overlay(alignment: .topLeading) {
                        statsLine(stats)
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: space.gaps.stats)
                    }
            }
        }
    }

    /// The stats, and the turn line growing at their right end (spec phase 3). The line shows
    /// once the turn has a segment, even before the stats have a figure (as on the web).
    @ViewBuilder
    private func statsLine(_ stats: LiveStats, underRow: Bool = false) -> some View {
        let segments = !turn.timeline.segments(now: .now).isEmpty
        if !stats.text.isEmpty || segments {
            HStack(spacing: TurnSpace.Inset.row) {
                if !stats.text.isEmpty { StatsLine(stats: stats, underRow: underRow) }
                Spacer(minLength: 0)
                if segments { TurnLine(turn: turn, live: true) }
            }
        }
    }

    private func stats(at now: Date, _ state: LiveState?) -> LiveStats {
        var stats = LiveStats.of(turn, pulse: conversation.pulse, now: now)
        stats.thinking = state?.reasoningID != nil
        if waiting { stats.waited = conversation.waitingSince.map { now.timeIntervalSince($0) } ?? 0 }
        // An answer writing with nothing arriving says so in its stats.
        if state == nil, let last = conversation.pulse.lastTokenAt { stats.quiet = now.timeIntervalSince(last) }
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
            }
        }
        .buttonStyle(.plain)
        .focusable(state.reasoningID != nil)
        .onHover { hovered = $0 }
        .metricsRow(.live, open && state.thought ? state.label : state.text, key: "live-\(turn.id)", fontSize: Tokens.Transcript.status.size)
    }

    @ViewBuilder
    private func detail(_ state: LiveState) -> some View {
        if state.thought {
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
    /// Under the live row: with its words, one mark column in. Under a writing answer: on the line.
    var underRow = false

    var body: some View {
        // Its parts with a 10 pt gap, no separator characters, as the footer and the web draw
        // metadata (5b76372f; spec, "The stats line"). Read aloud with commas.
        HStack(spacing: 10) {
            ForEach(Array(stats.parts.enumerated()), id: \.offset) { _, part in Text(part) }
        }
            .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
            .foregroundStyle(Tokens.textTertiary)
            .frame(height: Tokens.Transcript.meta.line, alignment: .leading)
            .help(stats.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stats.text)
            // On the words, inside the mark column: what the metrics report is where they start.
            .metricsFirstWord()
            .padding(.leading, underRow ? Tokens.Transcript.Layout.hang : 0)
            .metricsRow(.stats, stats.parts.joined(separator: " "), key: "stats", fontSize: Tokens.Transcript.meta.size,
                        sub: underRow ? "after" : nil)
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
