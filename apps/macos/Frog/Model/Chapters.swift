import Foundation

/// Chapters for the timeline rail: where a long conversation changes topic, so the rail can
/// mark them and scrubbing lands on one. Derived from what's in the log — a chapter starts at
/// each prompt of yours (a new ask is a new topic), at a compaction (the summarized boundary),
/// and after a long run with no prompt of yours (an autonomous stretch reads as its own
/// chapter). Topic-shift detection inside a turn's text is a follow-up.
struct Chapter {
    /// The turn the chapter starts at.
    let turn: TurnState.ID
    /// Its number, for the label.
    let number: UInt64?
    /// Why it starts here.
    let kind: Kind

    enum Kind {
        /// A prompt of yours.
        case prompt
        /// The context was summarized (a compaction boundary).
        case compacted
        /// A long run with no prompt in it (an autonomous stretch).
        case run
    }

    /// A run breaks into a chapter after this many turns with no prompt.
    static let runAfter = 6

    static func of(_ turns: [TurnState]) -> [Chapter] {
        guard !turns.isEmpty else { return [] }
        var out: [Chapter] = []
        var sincePrompt = 0
        for (i, turn) in turns.enumerated() {
            let compacted = turn.items.contains { item in
                if case .notice(let warning) = item.kind, !warning,
                   item.text.localizedCaseInsensitiveContains("summarized the conversation") { return true }
                return false
            }
            let isPrompt = !turn.input.isEmpty || !turn.more.isEmpty
            if i == 0 || isPrompt {
                out.append(Chapter(turn: turn.id, number: turn.number, kind: .prompt))
                sincePrompt = 0
            } else if compacted {
                out.append(Chapter(turn: turn.id, number: turn.number, kind: .compacted))
                sincePrompt = 0
            } else if sincePrompt >= Chapter.runAfter {
                out.append(Chapter(turn: turn.id, number: turn.number, kind: .run))
                sincePrompt = 0
            } else {
                sincePrompt += 1
            }
        }
        return out
    }

    /// The index in `turns` each chapter starts at, in order.
    static func starts(of chapters: [Chapter], in turns: [TurnState]) -> [Int] {
        chapters.compactMap { c in turns.firstIndex { $0.id == c.turn } }
    }

    /// The chapter a turn is in: the last one starting at or before it. Binary search.
    static func index(of i: Int, in starts: [Int]) -> Int? {
        guard !starts.isEmpty, i >= starts[0] else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= i { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
