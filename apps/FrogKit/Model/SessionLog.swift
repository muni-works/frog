import Foundation

/// A session's log (`<sessions>/<id>.jsonl`) read for opening it: mapped rather than read, and
/// indexed by line (where each event is, and which start a turn or an item) without parsing
/// any of it, so a picked session decodes only its newest rows before it's on screen and the
/// rest after, off the main thread. A long session's log is mostly what the transcript never
/// shows up front: model messages, screenshots in old tool results.
final class SessionLog: @unchecked Sendable {
    enum Kind: UInt8 {
        case turnStarted
        case itemStarted
        /// State a transcript needs whatever's on screen (the title, a moved folder).
        case meta
        case other
    }

    struct Line {
        let start: Int
        let end: Int
        let kind: Kind
    }

    let url: URL
    /// Bytes indexed: up to the end of the last whole line (a line being written isn't yet).
    let length: Int
    /// The file's identity when it was indexed, to tell a grown log from a replaced one.
    let inode: UInt64
    /// Event lines, in order.
    let events: [Line]
    /// Where turns start, as indices into `events`.
    let turnStarts: [Int]
    private let data: Data

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        self.url = url
        self.data = data
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var events: [Line] = []
        var turnStarts: [Int] = []
        var length = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var at = 0
            while at < count {
                guard let nl = memchr(base + at, 0x0A, count - at) else { break }
                let end = base.distance(to: UnsafeRawPointer(nl))
                if let kind = Self.kind(base + at, end - at) {
                    if kind == .turnStarted { turnStarts.append(events.count) }
                    events.append(Line(start: at, end: end, kind: kind))
                }
                at = end + 1
                length = at
            }
        }
        self.events = events
        self.turnStarts = turnStarts
        self.length = length
    }

    private static let eventPrefix = Array(#"{"type":"event""#.utf8)
    private static let tag = Array(#""event":""#.utf8)
    private static let turnStarted = Array(#"turn_started""#.utf8)
    private static let itemStarted = Array(#"item_started""#.utf8)
    private static let metas = [#"titled""#, #"folder_changed""#].map { Array($0.utf8) }

    /// What a line is, from its first bytes; nil for a record that isn't an event (the model's
    /// messages, checkpoints). The envelope's fields come in a fixed order (seq, session,
    /// created, then the event's tag), so the tag is near the start of the line.
    private static func kind(_ line: UnsafeRawPointer, _ length: Int) -> Kind? {
        guard length > eventPrefix.count,
              memcmp(line, eventPrefix, eventPrefix.count) == 0 else { return nil }
        let window = min(length, 320)
        guard let hit = memmem(line, window, tag, tag.count) else { return .other }
        let name = UnsafeRawPointer(hit) + tag.count
        let left = window - line.distance(to: name)
        func starts(_ word: [UInt8]) -> Bool { left >= word.count && memcmp(name, word, word.count) == 0 }
        if starts(turnStarted) { return .turnStarted }
        if starts(itemStarted) { return .itemStarted }
        if metas.contains(where: starts) { return .meta }
        return .other
    }

    /// The first event of the turns that hold the last `rows` rows (at least the last turn).
    func tailStart(rows: Int) -> Int {
        guard let lastTurn = turnStarts.last else { return 0 }
        var counted = 0
        var i = events.count - 1
        var start = lastTurn
        for t in turnStarts.indices.reversed() {
            let from = turnStarts[t]
            while i >= from {
                if events[i].kind == .itemStarted { counted += 1 }
                i -= 1
            }
            start = from
            if counted >= rows { break }
        }
        // Nothing before the first turn is a row of its own; it goes with the first turn.
        return start == turnStarts.first ? 0 : start
    }

    private struct Record: Decodable {
        let env: Envelope
    }

    /// The events in `range` (indices into `events`), decoded; lines that don't decode (an
    /// event this app doesn't know, a torn write) are left out.
    func decode(_ range: Range<Int>) -> [Envelope] {
        let decoder = JSONDecoder.frog
        return events[range].compactMap { line in
            try? decoder.decode(Record.self, from: data.subdata(in: line.start..<line.end)).env
        }
    }

    /// The `meta` events before `end`.
    func meta(before end: Int) -> [Envelope] {
        let decoder = JSONDecoder.frog
        return events[..<end].lazy.filter { $0.kind == .meta }.compactMap { line in
            try? decoder.decode(Record.self, from: self.data.subdata(in: line.start..<line.end)).env
        }
    }
}

/// A reopened session's history as it opens: its newest rows decoded, and the log they came
/// from for the rest. Remembered per session (`open`), so going back to one opened a moment ago
/// decodes nothing until its log grows.
struct SessionHistory: @unchecked Sendable {
    let log: SessionLog
    /// Where the tail starts, in the log's events; everything before is older.
    let tailStart: Int
    /// The tail's events, and the state events from before it.
    let tail: [Envelope]
    let meta: [Envelope]

    /// Rows decoded up front: a window and a half of them, and older ones as you scroll up.
    static let tailRows = 50

    /// The last few sessions opened, by id.
    @MainActor private static var cache: [String: SessionHistory] = [:]
    @MainActor private static var order: [String] = []
    @MainActor static var cacheLimit = 8
    #if DEBUG
    /// Opens served from the cache, for the switch benchmark.
    @MainActor static var cacheHits = 0
    #endif

    /// The history of session `id` from its log at `url`: from the cache when the log hasn't
    /// changed since (same file, same length), else read now. Nil when there's no log to read.
    @MainActor
    static func open(_ id: String, at url: URL, rows: Int = tailRows) -> SessionHistory? {
        if let hit = cache[id], hit.log.url == url, unchanged(hit.log) {
            #if DEBUG
            cacheHits += 1
            #endif
            touch(id)
            return hit
        }
        cache[id] = nil
        guard let log = SessionLog(url: url), !log.events.isEmpty else { return nil }
        let start = log.tailStart(rows: rows)
        let history = SessionHistory(log: log, tailStart: start, tail: log.decode(start..<log.events.count),
                                     meta: log.meta(before: start))
        cache[id] = history
        touch(id)
        return history
    }

    /// Read and decode the history off the main thread, then keep it for `open`: a click
    /// changes the screen at once and the log is read meanwhile.
    static func prefetch(_ id: String, at url: URL, rows: Int = tailRows) async {
        if await MainActor.run(body: { cache[id].map { $0.log.url == url && unchanged($0.log) } ?? false }) { return }
        let read: SessionHistory? = await Task.detached(priority: .userInitiated) {
            guard let log = SessionLog(url: url), !log.events.isEmpty else { return nil }
            let start = log.tailStart(rows: rows)
            return SessionHistory(log: log, tailStart: start, tail: log.decode(start..<log.events.count),
                                  meta: log.meta(before: start))
        }.value
        guard let read else { return }
        await MainActor.run {
            cache[id] = read
            touch(id)
        }
    }

    /// Forget a session's history (its log changed under it in a way a length can't tell).
    @MainActor static func forget(_ id: String) {
        cache[id] = nil
        order.removeAll { $0 == id }
    }

    @MainActor private static func touch(_ id: String) {
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > cacheLimit { cache[order.removeFirst()] = nil }
    }

    /// The log on disk is still the one indexed: the same file, with nothing appended. A new
    /// event grows it, so a cached tail is never stale.
    private static func unchanged(_ log: SessionLog) -> Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: log.url.path),
              let size = (a[.size] as? NSNumber)?.intValue,
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value else { return false }
        return inode == log.inode && size == log.length
    }

    /// Older turns' events, `before` an event index, in chunks starting at a turn: about `rows`
    /// rows' worth, decoded where it's called (off the main thread).
    func olderChunk(before end: Int, rows: Int) -> (start: Int, events: [Envelope]) {
        guard end > 0 else { return (0, []) }
        var start = end
        var counted = 0
        let starts = log.turnStarts
        // The turn starts before `end`, newest first, until there are enough rows.
        var t = (starts.lastIndex { $0 < end }) ?? -1
        while t >= 0 {
            let from = starts[t]
            for i in from..<start where log.events[i].kind == .itemStarted { counted += 1 }
            start = from
            t -= 1
            if counted >= rows { break }
        }
        if t < 0 { start = 0 }
        return (start, log.decode(start..<end))
    }
}
