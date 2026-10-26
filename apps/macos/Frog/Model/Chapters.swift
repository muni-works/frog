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

    /// `of`, kept for the turns it was last asked about: the rail lays out, hovers and drags by
    /// chapter, and folding a thousand turns per mouse move adds up.
    @MainActor private static var memo: (key: [AnyHashable], chapters: [Chapter], starts: [Int], titles: [String])?

    @MainActor static func cached(_ turns: [TurnState]) -> (chapters: [Chapter], starts: [Int], titles: [String]) {
        let key: [AnyHashable] = [turns.count, turns.first?.id, turns.last?.id, turns.last?.items.count]
        if let memo, memo.key == key { return (memo.chapters, memo.starts, memo.titles) }
        let chapters = of(turns)
        let starts = starts(of: chapters, in: turns)
        let titles = chapters.indices.map { c in
            let end = c + 1 < starts.count ? starts[c + 1] : turns.count
            return title(chapters[c], turns[starts[c]], turns: end - starts[c])
        }
        memo = (key, chapters, starts, titles)
        return (chapters, starts, titles)
    }

    /// A chapter's name, a few lowercase words: what you asked, the first clause of it with the
    /// lead-in dropped ("let's", "can you"), or what kind of stretch it is.
    static func title(_ chapter: Chapter, _ turn: TurnState, turns: Int) -> String {
        switch chapter.kind {
        case .compacted: return "summarized"
        case .run: return "on its own · \(turns) turn\(turns == 1 ? "" : "s")"
        case .prompt: break
        }
        if turn.input.hasPrefix("<") || turn.input.isEmpty { return "on its own · \(turns) turn\(turns == 1 ? "" : "s")" }
        if let w = words(turn.request), !w.isEmpty { return w }
        // Nothing worded ("?", an emoji): as typed, when it's short.
        let raw = turn.request.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, raw.count <= 24 { return raw }
        return turn.images.isEmpty ? "untitled" : "an image"
    }

    private static let leadIns = ["ok", "okay", "so", "hey", "please", "pls", "plz", "now", "alright",
                                  "let's", "lets", "let", "us", "can", "could", "would", "you",
                                  "i", "we", "want", "to", "should", "need", "actually", "also"]
    private static let trailing: Set<String> = ["a", "an", "the", "and", "or", "of", "on", "in", "to",
                                                "for", "with", "at", "by", "from", "it", "is", "that"]

    /// The first clause of `text`, lead-in dropped, at most four words, never ending on a
    /// connective.
    static func words(_ text: String) -> String? {
        let line = text.lowercased().split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // A period ends a sentence only before a space ("frog.app" is one word).
        let sentence = line.components(separatedBy: ". ").first ?? line
        let clause = sentence.split(whereSeparator: { ",:;?!()—–".contains($0) }).first.map(String.init) ?? ""
        var ws = clause.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
        while let w = ws.first, leadIns.contains(w), ws.count > 1 { ws.removeFirst() }
        ws = Array(ws.prefix(4))
        while let w = ws.last, trailing.contains(w), ws.count > 1 { ws.removeLast() }
        return ws.joined(separator: " ")
    }

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
            // Yours: a message from another session, a wakeup or a resume notice isn't a new
            // topic of yours (the chief's are nearly all from other sessions), it's the stretch
            // it lands in.
            let isPrompt = (!turn.input.isEmpty || !turn.more.isEmpty) && !turn.input.hasPrefix("<")
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
        let at = Dictionary(turns.indices.map { (turns[$0].id, $0) }, uniquingKeysWith: { a, _ in a })
        return chapters.compactMap { at[$0.turn] }
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
