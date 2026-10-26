import Foundation
import Observation

/// A conversation on your Mac, reached through the bridge: the phone's side of the same
/// `Conversation` the Mac uses. `subscribe` becomes attaching (history from the Mac's log, after
/// what's cached here), ops go to the Mac, and what the Mac says comes back as the engine's own
/// events. The transcript is cached here, so a thread opens at once and only what's new comes
/// over the wire.
@MainActor
@Observable
final class RemoteLink: ConversationLink {
    let session: String
    /// Open in a window on the Mac, so there's something there to take a message.
    var isOpenOnMac: Bool
    @ObservationIgnored weak var remote: Remote?
    @ObservationIgnored var onEvent: (Envelope?) -> Void = { _ in }
    /// The last durable event seen, to pick up after a reconnect.
    @ObservationIgnored private(set) var lastSeq: UInt64 = 0
    @ObservationIgnored private let cache: SessionCache

    init(session: String, remote: Remote, open: Bool) {
        self.session = session
        self.remote = remote
        isOpenOnMac = open
        cache = SessionCache(session: session)
    }

    var endDescription: String { "Lost the connection to your Mac." }

    func send(_ op: Op) {
        if case .subscribe = op {
            // What we saw last time, at once; then the Mac sends only what's new since.
            for raw in cache.load() {
                if let env = try? JSONDecoder.frog.decode(Envelope.self, from: raw) { receive(env, raw: nil) }
            }
            remote?.attach(session, after: lastSeq)
            return
        }
        guard let data = try? JSONEncoder().encode(op),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        remote?.send(op: dict, in: session)
    }

    func stop() {
        cache.flush()
        remote?.detach(session)
    }

    /// An event from the Mac (or the cache, `raw` nil).
    func receive(_ env: Envelope, raw: Data?) {
        if env.event.isDurable {
            if let raw, env.seq > lastSeq { cache.append(raw) }
            lastSeq = max(lastSeq, env.seq)
        }
        if case .turnEnded = env.event { cache.flush() }
        onEvent(env)
    }

    /// The Mac has sent all the history there is.
    func synced(upto: UInt64) {
        cache.flush()
        if let env = Envelope.make(session: session, ["event": "synced", "upto": upto]) { onEvent(env) }
    }

    /// The Mac couldn't do what we asked: say why, and stop looking busy.
    func refused(_ message: String) {
        for e: [String: Any] in [["event": "notice", "level": "warn", "message": message], ["event": "idle"]] {
            if let env = Envelope.make(session: session, e) { onEvent(env) }
        }
    }
}

extension Envelope {
    /// An envelope for an event this side makes up (a `synced`, a notice), as the engine would.
    static func make(session: String, _ event: [String: Any]) -> Envelope? {
        var e = event
        e["seq"] = 0
        e["session"] = session
        e["created"] = Int64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: e) else { return nil }
        return try? JSONDecoder.frog.decode(Envelope.self, from: data)
    }
}

extension Event {
    /// Mirrors the engine's `Event::is_durable`: what the session log keeps.
    var isDurable: Bool {
        switch self {
        case .turnStarted, .turnEnded, .itemStarted, .itemCompleted, .permissionResolved, .autoApproved,
             .compacted, .compactionFailed, .contextPruned, .modelChanged, .folderChanged, .modeChanged, .titled:
            true
        default:
            false
        }
    }
}

/// A conversation's durable events, kept on the phone. It's a cache: losing it just means a
/// longer first load.
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

/// What the phone does when things happen in a conversation: the lock screen's Live Activity
/// follows it. (Sounds and the frog's face are the same everywhere, in `Conversation`.)
@MainActor
final class PhoneEffects: ConversationEffects {
    static let shared = PhoneEffects()

    func turnEnded(_ c: Conversation, turn: TurnState) {}
    func asked(_ c: Conversation, _ request: PermissionRequest) {}
    func answered(_ c: Conversation, permission id: String) {}
    func live(_ c: Conversation, running: Bool, waiting: Bool) {
        LiveActivities.shared.follow(c)
    }
}
