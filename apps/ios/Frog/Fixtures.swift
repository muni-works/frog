import Foundation

/// Recorded sessions (the Mac's test fixtures) played back as if frog on the Mac were running
/// them, through the same `Conversation` and transcript: answers stream in, tools take their
/// time, and the first command or edit stops to ask. For designing and screenshotting without a
/// Mac. Launch with `-fixtures YES` for the list, or `-fixture <name>` to open one.
@MainActor
final class FixturePlayer: ConversationLink {
    static var names: [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: "Fixtures") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Recordings playing now, so answers from the Live Activity and the watch reach them.
    static var playing: [String: FixturePlayer] = [:]

    static func session(_ name: String) -> RemoteSession? {
        guard let (header, _) = load(name) else { return nil }
        return RemoteSession([
            "id": "fixture-\(name)",
            "title": name.replacingOccurrences(of: "-", with: " ").capitalized,
            "model": header["model"] as? String ?? "ollama/qwen3:4b",
            "folder": ((header["cwd"] as? String ?? "demo") as NSString).lastPathComponent,
            "cwd": header["cwd"] as? String ?? "/demo",
            "modified": Date().timeIntervalSince1970 * 1000,
            "open": true,
        ])
    }

    let session: RemoteSession
    private(set) var conversation: Conversation!
    var onEvent: (Envelope?) -> Void = { _ in }
    var endDescription: String { "The recording ended." }
    private let events: [[String: Any]]
    private var seq: UInt64 = 1000
    private var answered: CheckedContinuation<Void, Never>?
    private var stopped = false
    /// Stop at the first command or edit and ask, as frog does in the default mode.
    private let ask: Bool

    init?(name: String, ask: Bool = true) {
        guard let (_, events) = Self.load(name), let session = Self.session(name) else { return nil }
        self.events = events
        self.ask = ask
        self.session = session
        conversation = Conversation(folder: URL(fileURLWithPath: session.cwd ?? "/demo"), link: self, replay: false, session: session.id)
    }

    private static func load(_ name: String) -> ([String: Any], [[String: Any]])? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var header: [String: Any] = [:]
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["type"] as? String == "header" { header = obj }
            if obj["type"] as? String == "event", let env = obj["env"] as? [String: Any] { events.append(env) }
        }
        return (header, events)
    }

    /// Play the recording: the first turn's prompt arrives as if you'd just sent it.
    func play() async {
        Self.playing[session.id] = self
        var asked = false
        emit(["event": "status", "model": session.model, "mode": "default", "cwd": session.cwd ?? "/demo", "messages": 0,
              "context_window": 32768, "tool_mode": "native", "tier": "medium", "todos": []])
        emit(["event": "idle"])
        for env in events {
            guard !stopped else { return }
            let name = env["event"] as? String ?? ""
            switch name {
            case "turn_started":
                try? await Task.sleep(for: .milliseconds(500))
                emit(env)
            case "item_started":
                try? await Task.sleep(for: .milliseconds(350))
                emit(env)
            case "item_completed":
                let item = env["item"] as? [String: Any] ?? [:]
                let id = env["id"] as? String ?? ""
                switch item["type"] as? String {
                case "message", "reasoning":
                    await stream(item["text"] as? String ?? "", id: id, type: item["type"] as! String == "message" ? "text" : "reasoning")
                case "tool_call":
                    let tool = item["name"] as? String ?? ""
                    if ask, !asked, ["Bash", "Edit", "Write"].contains(tool) {
                        asked = true
                        await askPermission(for: item, id: id)
                        guard !stopped else { return }
                    }
                    try? await Task.sleep(for: .milliseconds(tool == "Bash" ? 900 : 450))
                default: break
                }
                emit(env)
            case "turn_ended":
                try? await Task.sleep(for: .milliseconds(300))
                emit(env)
                emit(["event": "idle"])
                share(nil, running: false)
            default:
                emit(env)
            }
        }
    }

    /// The text in word-sized pieces at a model's pace, as the engine streams it. Thinking is
    /// long and folded away, so it goes by quickly.
    private func stream(_ text: String, id: String, type: String) async {
        var rest = Substring(text)
        while !rest.isEmpty, !stopped {
            let n = min(rest.count, type == "text" ? Int.random(in: 3...9) : Int.random(in: 60...120))
            let piece = rest.prefix(n)
            rest = rest.dropFirst(n)
            emit(["event": "item_delta", "id": id, "delta": ["type": type, "text": String(piece)]])
            try? await Task.sleep(for: .milliseconds(type == "text" ? 28 : 12))
        }
    }

    private func askPermission(for item: [String: Any], id: String) async {
        let name = item["name"] as? String ?? ""
        var req: [String: Any] = [
            "event": "permission_request", "id": "p-\(id)", "item": id, "name": name, "arg": item["arg"] ?? "",
            "always": name == "Bash" ? "always allow `\((item["arg"] as? String ?? "").split(separator: " ").first ?? "")`" : "allow all edits this session",
        ]
        if let diff = item["diff"] { req["preview"] = diff }
        emit(req)
        share(["id": "p-\(id)", "name": name, "arg": item["arg"] ?? ""], running: true)
        await withCheckedContinuation { answered = $0 }
        emit(["event": "permission_resolved", "id": "p-\(id)", "decision": "allow"])
        share(nil, running: true)
    }

    /// The recording as a list row, for the watch and widgets, as they'd see it from a Mac.
    private func share(_ question: [String: Any]?, running: Bool) {
        var row: [String: Any] = ["id": session.id, "title": session.title, "model": session.model, "open": true]
        if running {
            row["live"] = question == nil ? "running" : "waiting"
            row["activity"] = conversation.activityState.activity
        }
        if let question { row["question"] = question }
        let rows = RemoteSession(row).map { [$0] } ?? []
        WatchLink.shared.share(running ? rows : [])
        Glance.share(running ? rows : [], host: "Recording")
    }

    // MARK: ConversationLink

    func send(_ op: Op) {
        switch op {
        case .permission(_, let decision):
            if decision == .deny { stopped = true; finish(.denied) }
            answered?.resume()
            answered = nil
        case .interrupt:
            stopped = true
            answered?.resume()
            answered = nil
            finish(.cancelled)
        case .submit(let text, _):
            // A recording can't answer something new; frog says so, kindly.
            let n = (conversation.turns.compactMap(\.number).max() ?? 1) + 1
            let reply = "This is a recorded session, so I can't act on that here. Connect to frog on your Mac and I'll get right on it."
            Task {
                emit(["event": "turn_started", "turn": n, "input": text])
                emit(["event": "item_started", "id": "m\(n)", "kind": ["type": "message"]])
                await stream(reply, id: "m\(n)", type: "text")
                emit(["event": "item_completed", "id": "m\(n)", "item": ["type": "message", "text": reply]])
                emit(["event": "turn_ended", "turn": n, "reason": ["type": "complete"],
                      "usage": ["input_tokens": 120, "output_tokens": 30, "model_calls": 1]])
                emit(["event": "idle"])
            }
        default:
            break
        }
    }

    func stop() {
        stopped = true
        answered?.resume()
        answered = nil
        Self.playing[session.id] = nil
    }

    private enum Stop: String { case denied, cancelled }

    /// End the turn the way the engine would when you say no or stop it.
    private func finish(_ stop: Stop) {
        guard let n = conversation.turns.last?.number else { return }
        emit(["event": "turn_ended", "turn": n, "reason": ["type": stop.rawValue],
              "usage": ["input_tokens": 0, "output_tokens": 0, "model_calls": 0]])
        emit(["event": "idle"])
        share(nil, running: false)
    }

    private func emit(_ event: [String: Any]) {
        seq += 1
        var env = event
        env["seq"] = seq
        env["session"] = session.id
        env["created"] = Int64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let e = try? JSONDecoder.frog.decode(Envelope.self, from: data) else { return }
        onEvent(e)
    }
}
