import Foundation
import Observation

/// Where a conversation's ops go: frog on the Mac, or a recorded session playing back.
@MainActor
protocol SessionLink: AnyObject {
    func send(op: [String: Any], in session: String)
}

/// One conversation as the phone sees it: the engine's events folded into turns, the same way
/// the Mac's `Conversation` does, minus the parts that belong to the Mac (stats, titles).
@MainActor
@Observable
final class SessionModel: Identifiable {
    struct Entry: Identifiable {
        enum Kind: Equatable {
            case message, reasoning, notice
            case tool(name: String, arg: String)
        }

        let id: String
        var kind: Kind
        var text = ""
        var output = ""
        var result: Item.ToolResult?
        var done = false
        var needsPermission = false
        /// Arrived live (not history): the text writes itself in.
        var live = false
        var startedAt: Date?
        var endedAt: Date?

        var isWork: Bool {
            switch kind {
            case .tool, .reasoning: true
            case .message, .notice: false
            }
        }
    }

    /// A turn's entries as they're shown: runs of work fold into one line, answers stand alone.
    enum Block: Identifiable {
        case work([Entry])
        case message(Entry)
        case notice(Entry)

        var id: String {
            switch self {
            case .work(let e): "work-" + (e.first?.id ?? "")
            case .message(let e), .notice(let e): e.id
            }
        }
    }

    struct Turn: Identifiable {
        let id = UUID()
        var number: UInt64?
        var input: String
        var entries: [Entry] = []
        var end: EndReason?
        var usage: TurnUsage?
        /// Sent from this phone (it springs in, like the Mac's sent bubble).
        var sentHere = false
        var startedAt: Date?
        var endedAt: Date?
        var finished: Bool { end != nil }

        var blocks: [Block] {
            var out: [Block] = []
            var run: [Entry] = []
            for e in entries {
                if e.isWork {
                    run.append(e)
                    continue
                }
                if !run.isEmpty { out.append(.work(run)); run = [] }
                if e.kind == .notice {
                    out.append(.notice(e))
                } else if !e.text.isEmpty {
                    out.append(.message(e))
                }
            }
            if !run.isEmpty { out.append(.work(run)) }
            return out
        }
    }

    let id: String
    let session: RemoteSession
    private(set) var turns: [Turn] = []
    private(set) var busy = false
    private(set) var permission: PermissionRequest?
    private(set) var status: Status?
    /// History is still arriving.
    private(set) var loading = true
    var isOpenOnMac: Bool
    /// The last durable event seen, to pick up from after a reconnect.
    private(set) var lastSeq: UInt64 = 0
    /// Bumped as live work lands, for haptics and sounds.
    private(set) var stepsDone = 0
    private(set) var turnsDone = 0
    private(set) var failures = 0
    /// A turn just finished: the frog is pleased for a moment.
    private(set) var justFinished = false
    @ObservationIgnored private weak var link: SessionLink?
    @ObservationIgnored private let cache: SessionCache?
    @ObservationIgnored private var finishedTask: Task<Void, Never>?

    init(session: RemoteSession, link: SessionLink, cached: Bool = true) {
        id = session.id
        self.session = session
        self.link = link
        isOpenOnMac = session.open
        cache = cached ? SessionCache(session: session.id) : nil
        // What we saw last time, at once; the Mac sends only what's new since.
        for raw in cache?.load() ?? [] {
            if let env = try? JSONDecoder.frog.decode(Envelope.self, from: raw) { apply(env) }
        }
        if !turns.isEmpty { loading = false }
    }

    func relink(_ link: SessionLink) {
        self.link = link
    }

    var model: String { status?.model ?? session.model }
    var isLocal: Bool { Models.isLocal(model) }

    /// What the frog's face should say.
    var mood: FrogMood {
        if permission != nil { return .waiting }
        if let end = turns.last?.end, case .error = end, justFinished { return .sad }
        if justFinished { return .done }
        guard busy, let last = turns.last?.entries.last(where: { $0.kind != .notice }) else {
            return busy ? .thinking : .idle
        }
        switch last.kind {
        case .reasoning: return last.done ? .thinking : .thinking
        case .tool(let name, _) where !last.done:
            return ["Read", "Grep", "Glob", "CodeMap", "Docs", "WebFetch", "WebSearch"].contains(name) ? .reading : .working
        case .message: return last.done ? .thinking : .working
        default: return .thinking
        }
    }

    // MARK: Actions

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(Turn(number: nil, input: text, sentHere: true, startedAt: .now))
        busy = true
        FrogSounds.shared.play(.plip)
        link?.send(op: ["op": "submit", "text": text], in: id)
    }

    func answer(_ decision: Decision) {
        guard let p = permission else { return }
        link?.send(op: ["op": "permission", "id": p.id, "decision": decision.rawValue], in: id)
        permission = nil
    }

    func interrupt() {
        link?.send(op: ["op": "interrupt"], in: id)
    }

    // MARK: Events

    func synced() {
        loading = false
        cache?.flush()
    }

    func note(_ text: String) {
        let e = Entry(id: UUID().uuidString, kind: .notice, text: text, done: true)
        if turns.isEmpty { turns.append(Turn(number: nil, input: "")) }
        turns[turns.count - 1].entries.append(e)
        // A message the Mac couldn't take isn't running.
        if let last = turns.indices.last, turns[last].sentHere, turns[last].number == nil {
            turns[last].end = .cancelled
            busy = false
        }
    }

    /// Fold an event in. `raw` is its JSON, kept for the transcript cache.
    func apply(_ env: Envelope, raw: Data? = nil) {
        if env.event.isDurable {
            if let raw, env.seq > lastSeq { cache?.append(raw) }
            lastSeq = max(lastSeq, env.seq)
        }
        let at = Date(timeIntervalSince1970: Double(env.created) / 1000)
        switch env.event {
        case .turnStarted(let n, let input, _):
            if let i = turns.lastIndex(where: { $0.number == nil && !$0.finished && $0.input == input }) {
                turns[i].number = n
                turns[i].startedAt = at
            } else if !turns.contains(where: { $0.number == n }) {
                turns.append(Turn(number: n, input: input, startedAt: at))
            }
            if !loading { busy = true }
        case .turnEnded(let n, let reason, let usage):
            if let i = turns.lastIndex(where: { $0.number == n }) {
                turns[i].end = reason
                turns[i].usage = usage
                turns[i].endedAt = at
            }
            if !loading {
                turnsDone += 1
                if case .complete = reason { FrogSounds.shared.play(.ribbit) }
                celebrate()
                cache?.flush()
            }
        case .itemStarted(let id, let kind):
            let live = !loading
            upsert(id) { e in
                e.kind = Self.kind(kind)
                e.live = e.live || live
                if e.startedAt == nil { e.startedAt = at }
            }
        case .itemDelta(let id, let delta):
            upsert(id) { e in
                switch delta {
                case .text(let t), .reasoning(let t): e.text += t
                case .output(let t): e.output += t
                }
            }
        case .itemCompleted(let id, let item):
            var failed = false
            upsert(id) { e in
                e.done = true
                e.needsPermission = false
                e.endedAt = at
                switch item {
                case .message(let t): e.kind = .message; e.text = t
                case .reasoning(let t): e.kind = .reasoning; e.text = t
                case .toolCall(let r):
                    e.kind = .tool(name: r.name, arg: r.arg)
                    e.result = r
                    failed = r.outcome == .error
                }
            }
            if !loading, case .toolCall = item {
                stepsDone += 1
                if failed { failures += 1 }
            }
        case .permissionRequest(let req):
            permission = req
            upsert(req.item) { $0.needsPermission = true }
            if !loading { FrogSounds.shared.play(.drip) }
        case .permissionResolved:
            permission = nil
        case .status(let s):
            status = s
        case .idle:
            busy = false
            permission = nil
        case .notice(let level, let message) where level == "warn":
            note(message)
        case .error(let e):
            note(e.description)
        default:
            break
        }
        if !loading, !env.event.isQuiet { LiveActivities.shared.follow(self) }
    }

    func close() {
        cache?.flush()
    }

    private func celebrate() {
        justFinished = true
        finishedTask?.cancel()
        finishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.justFinished = false
        }
    }

    private static func kind(_ k: ItemKind) -> Entry.Kind {
        switch k {
        case .message: .message
        case .reasoning: .reasoning
        case .toolCall(let name, let arg): .tool(name: name, arg: arg)
        }
    }

    private func upsert(_ id: String, _ update: (inout Entry) -> Void) {
        for t in turns.indices.reversed() {
            if let i = turns[t].entries.firstIndex(where: { $0.id == id }) {
                update(&turns[t].entries[i])
                return
            }
        }
        if turns.isEmpty { turns.append(Turn(number: nil, input: "")) }
        var e = Entry(id: id, kind: .message)
        update(&e)
        turns[turns.count - 1].entries.append(e)
    }
}

extension Event {
    /// Streaming text: the lock screen doesn't need to hear about every word.
    var isQuiet: Bool {
        if case .itemDelta = self { true } else { false }
    }

    /// Mirrors the engine's `Event::is_durable`: what the session log keeps.
    var isDurable: Bool {
        switch self {
        case .turnStarted, .turnEnded, .itemStarted, .itemCompleted, .permissionResolved, .autoApproved,
             .compacted, .contextPruned, .modelChanged, .folderChanged, .modeChanged, .titled:
            true
        default:
            false
        }
    }
}

/// A conversation's durable events, kept on the phone so a thread opens at once and only
/// what's new comes over the wire. It's a cache: losing it just means a longer first load.
@MainActor
final class SessionCache {
    private let url: URL
    private var pending: [Data] = []

    init(session: String) {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "\(session).jsonl")
    }

    func load() -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }

    func append(_ raw: Data) {
        pending.append(raw)
    }

    func flush() {
        guard !pending.isEmpty else { return }
        var blob = Data()
        for p in pending { blob.append(p); blob.append(0x0A) }
        pending = []
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(blob)
            try? h.close()
        } else {
            try? blob.write(to: url)
        }
    }
}
