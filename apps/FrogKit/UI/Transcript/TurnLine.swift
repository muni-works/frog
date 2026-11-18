import SwiftUI

// The turn line and the turn panel (docs/design/transcript/spec.md, phase 3; board 7, set to
// boards 9 and 8). One small graphic at the right end of the stats while live and of the footer
// at rest: a strip coloured by what Frog was doing, the pace curve above it. Grey until hovered;
// hover scrubs; a click on a segment goes to its step, anywhere else opens the turn panel.

/// What the turn line and the panel share with the rows: the step under the pointer (its line
/// gets the hover plate), a step to scroll to, and the turn whose panel is open. Kept apart from
/// the transcript's scroll-follow state.
@Observable
final class TurnFocus {
    var scrubbed: String?
    var reveal: String?
    var panel: TurnState.ID?
}

extension EnvironmentValues {
    @Entry var turnFocus: TurnFocus?
}

/// The graphic, worked out once (pure, so it's tested): strip pieces and the pace curve in a
/// `width` × `height` box.
struct TurnLineShape: Equatable {
    struct Piece: Equatable {
        var kind: TurnTimeline.Kind
        var x: CGFloat
        var width: CGFloat
        var item: String?
        var startMs: UInt64
        var endMs: UInt64
    }

    var pieces: [Piece]
    /// The curve's points, x and y (y down), empty when there's no pace or no room for it.
    var curve: [CGPoint]
    var lengthMs: UInt64

    static let width: CGFloat = 200
    static let height: CGFloat = 16
    static let strip: CGFloat = 4

    static func of(segments: [TurnTimeline.Segment], lengthMs: UInt64, pace: TurnUsage.Pace?,
                   width: CGFloat = width, height: CGFloat = height, curve showCurve: Bool = true) -> TurnLineShape {
        let total = max(1, lengthMs)
        let k = width / CGFloat(total)
        // Thinking and writing are what the curve is about; draw tools and waits under them, so
        // a short write shows over a long tool.
        let pieces = segments.map { s in
            Piece(kind: s.kind, x: CGFloat(s.startMs) * k, width: max(1, CGFloat(s.endMs - min(s.endMs, s.startMs)) * k),
                  item: s.item, startMs: s.startMs, endMs: s.endMs)
        }
        var points: [CGPoint] = []
        if showCurve, let pace, pace.bucketMs > 0, !pace.tokens.isEmpty {
            let rates = pace.tokens.map { Double($0) * 1000 / Double(pace.bucketMs) }
            let top = max(1, rates.max() ?? 1)
            let room = height - strip - 2
            for (i, r) in rates.enumerated() {
                let x = (CGFloat(i) + 0.5) * CGFloat(pace.bucketMs) * k
                guard x <= width else { break }
                points.append(CGPoint(x: x, y: height - strip - 1 - CGFloat(r / top) * room))
            }
        }
        return TurnLineShape(pieces: pieces, curve: points, lengthMs: total)
    }

    /// The segment under x: the narrowest one covering it (a write over a long tool).
    func piece(at x: CGFloat) -> Piece? {
        pieces.filter { x >= $0.x && x <= $0.x + $0.width }.min { $0.width < $1.width }
    }

    /// The pace at x, in tokens per second.
    static func rate(at ms: UInt64, pace: TurnUsage.Pace?) -> Int? {
        guard let pace, pace.bucketMs > 0 else { return nil }
        let i = Int(ms / pace.bucketMs)
        guard i < pace.tokens.count else { return 0 }
        return Int((Double(pace.tokens[i]) * 1000 / Double(pace.bucketMs)).rounded())
    }
}

extension TurnTimeline.Kind {
    /// The strip's colour on hover: thinking frog green, tools faint, waiting amber, writing text.
    var color: Color {
        switch self {
        case .thinking: Tokens.accent
        case .tool: Tokens.textTertiary
        case .waiting: Tokens.notice
        case .writing: Tokens.text
        }
    }

    var words: String {
        switch self {
        case .thinking: "Thinking"
        case .tool: "Tools"
        case .waiting: "Waiting on you"
        case .writing: "Writing"
        }
    }
}

/// The line: grey at rest, its colours over 150 ms on hover, a hairline and a readout under the
/// pointer.
struct TurnLine: View {
    let turn: TurnState
    var live = false
    @Environment(\.turnFocus) private var focus
    @Environment(\.transcriptEdge) private var edge
    @State private var pointer: CGFloat?

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 0.5 : 3600)) { ctx in
            let now: Date? = live ? ctx.date : nil
            let shape = TurnLineShape.of(segments: turn.timeline.segments(now: now), lengthMs: turn.timeline.length(now: now),
                                         pace: turn.usage?.pace, curve: !edge.narrowLine)
            let hovered = pointer != nil
            Canvas { g, size in
                for p in shape.pieces.sorted(by: { $0.width > $1.width }) {
                    let r = CGRect(x: p.x, y: size.height - TurnLineShape.strip, width: max(1, p.width - 0.5), height: TurnLineShape.strip)
                    let tone: Color = hovered ? p.kind.color : (p.kind == .tool ? Tokens.textQuaternary : Tokens.textTertiary)
                    g.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(tone))
                    if let pointer, let under = shape.piece(at: pointer), under == p {
                        g.fill(Path(roundedRect: r.insetBy(dx: 0, dy: -1), cornerRadius: 1), with: .color(tone))
                    }
                }
                if shape.curve.count > 1 {
                    var path = Path()
                    path.addLines(shape.curve)
                    g.stroke(path, with: .color(hovered ? Tokens.textSecondary : Tokens.textTertiary), lineWidth: 1)
                }
                if let pointer {
                    g.fill(Path(CGRect(x: pointer, y: 0, width: 0.5, height: size.height)), with: .color(Tokens.textSecondary))
                }
            }
            .frame(width: TurnLineShape.width, height: TurnLineShape.height)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    pointer = at.x
                    focus?.scrubbed = shape.piece(at: at.x)?.item
                case .ended:
                    pointer = nil
                    focus?.scrubbed = nil
                }
            }
            .onTapGesture { at in
                if let piece = shape.piece(at: at.x), let item = piece.item, piece.kind != .writing {
                    focus?.reveal = item
                } else {
                    focus?.panel = turn.id
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let pointer {
                    Text(readout(shape, at: pointer))
                        .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
                        .foregroundStyle(Tokens.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, TurnSpace.Inset.row).padding(.vertical, TurnSpace.Inset.hair)
                        .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.control))
                        .offset(y: -TurnLineShape.height - TurnSpace.Inset.tight)
                        .allowsHitTesting(false)
                }
            }
            .help(pointer == nil ? "This turn: click to open it" : "")
            .metricsRow(.turnline, "", key: "turnline-\(turn.id)-\(live)", fontSize: 0)
            .accessibilityLabel("Turn timeline")
            .accessibilityAddTraits(.isButton)
        }
    }

    /// "20s · 0 tok/s · Ran cargo test -q upload · 9s · failed".
    private func readout(_ shape: TurnLineShape, at x: CGFloat) -> String {
        let ms = UInt64(max(0, x / TurnLineShape.width * CGFloat(shape.lengthMs)))
        var parts = [LiveStats.clock(Double(ms) / 1000)]
        if let rate = TurnLineShape.rate(at: ms, pace: turn.usage?.pace) { parts.append("\(rate) tok/s") }
        if let piece = shape.piece(at: x) {
            parts.append(Self.step(piece, in: turn))
        }
        return parts.joined(separator: " · ")
    }

    /// A segment's step in words, for the readout ("Ran cargo test -q upload", "Thought", "Waited
    /// for you"): the step, not its result (spec: "time, speed then, and the step under it").
    static func step(_ piece: TurnLineShape.Piece, in turn: TurnState) -> String {
        if piece.kind == .waiting { return "Waited for you" }
        guard let item = turn.items.first(where: { $0.id == piece.item }) else { return piece.kind.words }
        switch item.kind {
        case .reasoning: return "Thought"
        case .message: return "Wrote the answer"
        case .tool:
            guard let line = StepLine.of(item) else { return piece.kind.words }
            // A failed step reads as what it did ("Ran …"): the failure is its result.
            let verb = line.verb == Verbs.failed || line.verb == Verbs.denied || !line.gist.isEmpty
                ? Verbs.look(line.name).past : line.verb
            let object = line.object.isEmpty ? (StepLine.of(item.clearingGist)?.object ?? "") : line.object
            return [verb, object].filter { !$0.isEmpty }.joined(separator: " ")
        case .notice: return piece.kind.words
        }
    }

}

// MARK: - The panel

/// The turn, opened (board 7): over the transcript, which dims and doesn't reflow. Where the time
/// went, then every step as a bar on one time axis with the pace above, and the selected step's
/// detail beside. Esc or a click outside closes it.
struct TurnPanel: View {
    let turn: TurnState
    let conversation: Conversation
    let close: () -> Void
    @Environment(\.turnFocus) private var focus
    @Environment(\.models) private var models
    @State private var selected: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: turn.finished ? 3600 : 0.5)) { ctx in
            let now: Date? = turn.finished ? nil : ctx.date
            let segments = turn.timeline.segments(now: now)
            let length = turn.timeline.length(now: now)
            VStack(alignment: .leading, spacing: TurnSpace.Inset.roomy) {
                header(length: length)
                breakdown(segments)
                HStack(alignment: .top, spacing: TurnSpace.Inset.roomy) {
                    TurnWaterfall(turn: turn, segments: segments, lengthMs: length, selected: $selected)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if let id = selected, let item = turn.items.first(where: { $0.id == id }) {
                        detail(item)
                            .frame(width: 300, alignment: .topLeading)
                    }
                }
            }
        }
        .padding(TurnSpace.Card.padding + TurnSpace.Inset.tight)
        .frame(maxWidth: 820)
        .background(Tokens.raised, in: .rect(cornerRadius: Tokens.Radius.card))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onKeyPress(.escape) { close(); return .handled }
        .onExitCommand(perform: close)
    }

    private func header(length: UInt64) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: TurnSpace.Inset.hair) {
                Text("This turn").font(.frog(size: Tokens.Transcript.body.size, weight: .semibold))
                if let usage = turn.usage {
                    // The model and where it ran (Frog Cloud when it served the turn).
                    Text(EndView.footer(usage, models: models).compactMap { if case .model(let m) = $0 { m } else { nil } }.joined(separator: " · "))
                        .font(.frog(size: Tokens.Transcript.meta.size)).foregroundStyle(Tokens.textSecondary)
                }
            }
            Spacer()
            Text(totals(length: length)).font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
                .foregroundStyle(Tokens.textTertiary)
            Button { close() } label: { Image(systemName: "xmark").font(.frog(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Tokens.textTertiary).help("Close (Esc)")
        }
    }

    private func totals(length: UInt64) -> String {
        // The footer's time when the turn is done (its wall time), else the line's length so far.
        let ms = turn.finished ? (turn.usage?.timing?.wallMs ?? length) : length
        var parts = [StepLine.duration(Double(ms) / 1000)]
        if let usage = turn.usage {
            if usage.outputTokens > 0 { parts.append("\(usage.outputTokens.formatted()) tokens") }
            if let c = ModelStats.shared.cost(of: usage) { parts.append(ModelStats.money(c)) }
        }
        return parts.joined(separator: " · ")
    }

    /// Where the time went: thinking, tools, waiting on you, writing; then tokens read and from cache.
    private func breakdown(_ segments: [TurnTimeline.Segment]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TurnSpace.Inset.roomy + TurnSpace.Inset.row) {
            ForEach(Self.breakdown(segments), id: \.kind) { part in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: TurnSpace.Inset.tight) {
                        Circle().fill(part.kind.color).frame(width: 6, height: 6)
                        Text(part.kind.words).font(.frog(size: Tokens.Transcript.meta.size)).foregroundStyle(Tokens.textSecondary)
                    }
                    Text(StepLine.duration(Double(part.ms) / 1000)).font(.frog(size: Tokens.Transcript.body.size).monospacedDigit())
                }
            }
            Spacer()
            if let usage = turn.usage, usage.inputTokens > 0 {
                Text("Read \(usage.inputTokens.formatted()) tokens\(usage.cached > 0 ? ", \(usage.cached.formatted()) from cache" : "")")
                    .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit()).foregroundStyle(Tokens.textTertiary)
            }
        }
    }

    /// Each kind's time, as the union of its segments (steps that ran together count once).
    static func breakdown(_ segments: [TurnTimeline.Segment]) -> [(kind: TurnTimeline.Kind, ms: UInt64)] {
        [TurnTimeline.Kind.thinking, .tool, .waiting, .writing].compactMap { kind in
            let spans = segments.filter { $0.kind == kind }.map { ($0.startMs, $0.endMs) }.sorted { $0.0 < $1.0 }
            var total: UInt64 = 0
            var reach: UInt64 = 0
            for (a, b) in spans where b > max(a, reach) {
                total += b - max(a, reach)
                reach = b
            }
            return spans.isEmpty ? nil : (kind, total)
        }
    }

    @ViewBuilder
    private func detail(_ item: ItemState) -> some View {
        VStack(alignment: .leading, spacing: TurnSpace.Inset.row) {
            switch item.kind {
            case .reasoning:
                ThinkingOutline(item: item)
            case .tool(let name, _):
                if let line = StepLine.of(item) {
                    Text([line.verb, line.object].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.frog(size: Tokens.Transcript.status.size)).lineLimit(2)
                }
                ToolDetail(name: name, item: item, root: conversation.folder.path)
                    .frame(maxHeight: 320)
            default:
                Text(item.text).font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                    .lineLimit(12)
            }
            Button("Show in transcript") {
                focus?.reveal = item.id
                close()
            }
            .buttonStyle(.plain)
            .font(.frog(size: Tokens.Transcript.meta.size))
            .foregroundStyle(Tokens.textSecondary)
        }
    }
}

/// One row per step under a shared time axis with ticks, the pace above. Steps that ran together
/// overlap in time on their own rows; a wait over 30 s is drawn short and broken, its real length
/// written on it.
struct TurnWaterfall: View {
    let turn: TurnState
    let segments: [TurnTimeline.Segment]
    let lengthMs: UInt64
    @Binding var selected: String?

    static let longWait: UInt64 = 30_000
    static let rowHeight: CGFloat = 22

    struct Row: Identifiable, Equatable {
        var id: String
        var label: String
        var kind: TurnTimeline.Kind
        var startMs: UInt64
        var endMs: UInt64
        var item: String?
    }

    /// The rows in time order: a row per segment (a tool cut by a wait keeps one row, spanning).
    static func rows(_ segments: [TurnTimeline.Segment], turn: TurnState) -> [Row] {
        var out: [Row] = []
        for s in segments {
            let id = "\(s.kind.rawValue)-\(s.item ?? "")"
            if let i = out.firstIndex(where: { $0.id == id }) {
                out[i].endMs = max(out[i].endMs, s.endMs)
                continue
            }
            let piece = TurnLineShape.Piece(kind: s.kind, x: 0, width: 0, item: s.item, startMs: s.startMs, endMs: s.endMs)
            let label = TurnLine.step(piece, in: turn)
            out.append(Row(id: id, label: label, kind: s.kind, startMs: s.startMs, endMs: s.endMs, item: s.item))
        }
        return out
    }

    var body: some View {
        let rows = Self.rows(segments, turn: turn)
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let shape = TurnLineShape.of(segments: segments, lengthMs: lengthMs, pace: turn.usage?.pace,
                                             width: geo.size.width - 180, height: 28)
                Canvas { g, _ in
                    if shape.curve.count > 1 {
                        var path = Path()
                        path.addLines(shape.curve.map { CGPoint(x: $0.x + 180, y: $0.y) })
                        g.stroke(path, with: .color(Tokens.textSecondary), lineWidth: 1)
                    }
                }
            }
            .frame(height: 28)
            ForEach(rows) { row in
                Button { selected = row.item } label: { bar(row) }
                    .buttonStyle(.plain)
                    .background(selected == row.item && row.item != nil ? Tokens.hover : .clear, in: .rect(cornerRadius: Tokens.Transcript.Layout.plateRadius))
            }
            axis
        }
    }

    private func bar(_ row: Row) -> some View {
        GeometryReader { geo in
            let w = geo.size.width - 180
            let k = w / CGFloat(max(1, lengthMs))
            let span = row.endMs - min(row.endMs, row.startMs)
            let long = row.kind == .waiting && span > Self.longWait
            let width = long ? CGFloat(Self.longWait) * k * 0.4 : max(2, CGFloat(span) * k)
            HStack(spacing: 0) {
                Text(row.label).font(.frog(size: Tokens.Transcript.status.size)).foregroundStyle(Tokens.textSecondary)
                    .lineLimit(1).truncationMode(.middle).frame(width: 172, alignment: .leading)
                    .padding(.trailing, TurnSpace.Inset.row)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(row.kind.color.opacity(row.kind == .tool ? 1 : 0.85))
                        .frame(width: width, height: 8)
                        .overlay {
                            if long {
                                // Cut, not scaled: a break and the real length.
                                Rectangle().fill(Tokens.raised).frame(width: 3, height: 10).rotationEffect(.degrees(20))
                            }
                        }
                        .offset(x: CGFloat(row.startMs) * k)
                    Text(StepLine.duration(Double(span) / 1000))
                        .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
                        .foregroundStyle(Tokens.textTertiary)
                        .offset(x: CGFloat(row.startMs) * k + width + TurnSpace.Inset.tight)
                }
                .frame(width: w, alignment: .leading)
            }
        }
        .frame(height: Self.rowHeight)
        .contentShape(.rect)
    }

    private var axis: some View {
        GeometryReader { geo in
            let w = geo.size.width - 180
            let step = Self.tickStep(lengthMs)
            ZStack(alignment: .topLeading) {
                ForEach(Array(stride(from: UInt64(0), through: lengthMs, by: Int(step)).enumerated()), id: \.offset) { _, t in
                    Text(LiveStats.clock(Double(t) / 1000))
                        .font(.frog(size: Tokens.Transcript.meta.size).monospacedDigit())
                        .foregroundStyle(Tokens.textTertiary)
                        .offset(x: 180 + CGFloat(t) / CGFloat(max(1, lengthMs)) * w)
                }
            }
        }
        .frame(height: Tokens.Transcript.meta.line)
    }

    /// A tick every 1, 5, 15, 30 s or minute, whichever gives four to eight ticks.
    static func tickStep(_ ms: UInt64) -> UInt64 {
        for s in [1_000, 5_000, 15_000, 30_000, 60_000, 300_000] as [UInt64] where ms / s <= 8 { return s }
        return 600_000
    }
}
