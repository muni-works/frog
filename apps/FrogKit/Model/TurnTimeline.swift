import Foundation

/// A turn's timeline (docs/design/transcript/spec.md, phase 3): the stretches of thinking, tools,
/// waiting on a person and writing that the turn line's strip and the turn panel's waterfall
/// draw. The Mac records the few events that make them as they arrive (live or from a log) and
/// works the segments out itself; `crates/frog-engine/src/timeline.rs` is the reference and
/// `docs/design/transcript/timeline.json` the cases both must agree on.
struct TurnTimeline: Equatable {
    enum Kind: String, Comparable, Decodable {
        case thinking, tool, waiting, writing

        private var order: Int { [.thinking, .tool, .waiting, .writing].firstIndex(of: self) ?? 0 }
        static func < (a: Kind, b: Kind) -> Bool { a.order < b.order }
    }

    /// One stretch, in ms from the turn's start.
    struct Segment: Equatable, Decodable {
        var kind: Kind
        var startMs: UInt64
        var endMs: UInt64
        /// The reasoning, message or tool call it belongs to (for waiting, the call that asked).
        var item: String?
    }

    private enum Mark: Equatable {
        case started(id: String, kind: Kind, at: Int64)
        case completed(id: String, at: Int64, thinkMs: UInt64?)
        case wait(item: String?, asked: Int64, at: Int64)
        case discarded([String])
    }

    /// `turn_started`'s and `turn_ended`'s times, and the latest event's (unix ms).
    private(set) var startedAt: Int64?
    private(set) var endedAt: Int64?
    private(set) var lastAt: Int64?
    private var marks: [Mark] = []

    /// Takes the events that make segments; any other event only moves the latest time (an open
    /// item in a turn with no end runs to it). The app feeds it only the timing events and uses
    /// now for a live turn, so a delta never touches the turns.
    mutating func record(_ env: Envelope) {
        let t = env.created
        switch env.event {
        case .turnStarted:
            self = TurnTimeline()
            startedAt = t
        case .itemStarted(let id, let kind):
            let k: Kind = switch kind {
            case .reasoning: .thinking
            case .message: .writing
            case .toolCall: .tool
            }
            marks.append(.started(id: id, kind: k, at: t))
        case .itemCompleted(let id, let item):
            var think: UInt64?
            if case .reasoning(_, let meta) = item { think = meta.thinkMs }
            marks.append(.completed(id: id, at: t, thinkMs: think))
        case .permissionResolved(_, _, let item, let asked), .questionResolved(_, let item, let asked):
            if let asked { marks.append(.wait(item: item, asked: asked, at: t)) }
        case .itemsDiscarded(let ids):
            marks.append(.discarded(ids))
        case .turnEnded:
            endedAt = t
        default:
            break
        }
        guard startedAt != nil else { return }
        lastAt = max(lastAt ?? t, t)
    }

    /// The turn's length so far in ms (to its end, or its latest event, or `now` while live).
    func length(now: Date? = nil) -> UInt64 {
        guard let t0 = startedAt else { return 0 }
        let end = endedAt ?? now.map { Int64($0.timeIntervalSince1970 * 1000) } ?? lastAt ?? t0
        return UInt64(max(0, end - t0))
    }

    /// The segments, sorted by start, kind, item (timeline.rs's `segments`). An item still open
    /// ends at the turn's end, its latest event, or `now` while live.
    func segments(now: Date? = nil) -> [Segment] {
        guard let t0 = startedAt else { return [] }
        let end = max(t0, endedAt ?? now.map { Int64($0.timeIntervalSince1970 * 1000) } ?? lastAt ?? t0)
        func at(_ t: Int64) -> UInt64 { UInt64(min(max(t, t0), end) - t0) }
        var open: [String: (kind: Kind, start: Int64)] = [:]
        var out: [Segment] = []
        var waits: [Segment] = []
        var discarded = Set<String>()
        for mark in marks {
            switch mark {
            case .started(let id, let kind, let start):
                open[id] = (kind, start)
            case .completed(let id, let t, let thinkMs):
                guard let (kind, start) = open.removeValue(forKey: id) else { continue }
                let stop = thinkMs.map { min(start + Int64($0), t) } ?? t
                out.append(Segment(kind: kind, startMs: at(start), endMs: at(stop), item: id))
            case .wait(let item, let asked, let t):
                waits.append(Segment(kind: .waiting, startMs: at(asked), endMs: at(t), item: item))
            case .discarded(let ids):
                discarded.formUnion(ids)
            }
        }
        for (id, o) in open.sorted(by: { ($0.value.start, $0.key) < ($1.value.start, $1.key) }) {
            out.append(Segment(kind: o.kind, startMs: at(o.start), endMs: at(end), item: id))
        }
        out.removeAll { $0.item.map(discarded.contains) ?? false }
        // Each wait is cut out of its own tool's segment.
        var cut: [Segment] = []
        for s in out {
            guard s.kind == .tool else { cut.append(s); continue }
            var pieces = [(s.startMs, s.endMs)]
            for w in waits where w.item == s.item {
                pieces = pieces.flatMap { a, b in
                    [(a, min(w.startMs, b)), (max(w.endMs, a), b)].filter { $0.0 < $0.1 }
                }
            }
            cut += pieces.map { Segment(kind: s.kind, startMs: $0.0, endMs: $0.1, item: s.item) }
        }
        cut += waits
        return cut.sorted {
            ($0.startMs, $0.kind, $0.item ?? "", $0.endMs) < ($1.startMs, $1.kind, $1.item ?? "", $1.endMs)
        }
    }
}

/// Tuples of up to four comparables compare like Rust's; Swift's built-in `<` stops at six
/// elements but needs the element types to be the same comparable family, so spell it out.
private func < (a: (UInt64, TurnTimeline.Kind, String, UInt64), b: (UInt64, TurnTimeline.Kind, String, UInt64)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    if a.2 != b.2 { return a.2 < b.2 }
    return a.3 < b.3
}
