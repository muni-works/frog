import Foundation

/// Recorded sessions (the Mac's test fixtures) played back as if frog on the Mac were running
/// them: answers stream in, tools take their time, and one command stops to ask. For designing
/// and screenshotting without a Mac. Launch with `-fixtures` for the list, or
/// `-fixture <name>` to open one.
@MainActor
final class FixturePlayer: SessionLink {
    static var names: [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "jsonl", subdirectory: "Fixtures") ?? []
        return urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    static func session(_ name: String) -> RemoteSession? {
        guard let (header, _) = load(name) else { return nil }
        return RemoteSession([
            "id": "fixture-\(name)",
            "title": name.replacingOccurrences(of: "-", with: " ").capitalized,
            "model": header["model"] as? String ?? "ollama/qwen3:4b",
            "folder": ((header["cwd"] as? String ?? "demo") as NSString).lastPathComponent,
            "modified": Date().timeIntervalSince1970 * 1000,
            "open": true,
        ])
    }

    /// Recordings playing now, so answers from the Live Activity reach them.
    static var playing: [String: FixturePlayer] = [:]

    let model: SessionModel
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
        model = SessionModel(session: session, link: DeadLink.shared, cached: false)
        model.relink(self)
        model.synced()
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
        Self.playing[model.id] = self
        var asked = false
        emit(["event": "status", "model": model.session.model, "mode": "default", "cwd": "/demo", "messages": 0,
              "context_window": 32768, "tool_mode": "native", "tier": "medium", "todos": []])
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
            default:
                emit(env)
            }
        }
    }

    /// The text in word-sized pieces at a model's pace, as the engine streams it.
    private func stream(_ text: String, id: String, type: String) async {
        var rest = Substring(text)
        while !rest.isEmpty, !stopped {
            // Thinking is long and folded away; it goes by quickly.
            let n = min(rest.count, type == "text" ? Int.random(in: 3...9) : Int.random(in: 60...120))
            let piece = rest.prefix(n)
            rest = rest.dropFirst(n)
            emit(["event": "item_delta", "id": id, "delta": ["type": type, "text": String(piece)]])
            try? await Task.sleep(for: .milliseconds(type == "text" ? 28 : 12))
        }
    }

    private func askPermission(for item: [String: Any], id: String) async {
        var req: [String: Any] = [
            "event": "permission_request", "id": "p-\(id)", "item": id,
            "name": item["name"] ?? "", "arg": item["arg"] ?? "",
            "always": (item["name"] as? String) == "Bash" ? "\((item["arg"] as? String ?? "").split(separator: " ").first ?? "") commands" : "edits in this folder",
        ]
        if let diff = item["diff"] { req["preview"] = diff }
        emit(req)
        await withCheckedContinuation { answered = $0 }
        emit(["event": "permission_resolved", "id": "p-\(id)", "decision": "allow"])
    }

    func send(op: [String: Any], in session: String) {
        switch op["op"] as? String {
        case "permission":
            if op["decision"] as? String == "deny" { stopped = true; finish(.denied) }
            answered?.resume()
            answered = nil
        case "interrupt":
            stopped = true
            answered?.resume()
            answered = nil
            finish(.cancelled)
        case "submit":
            // A recording can't answer something new; frog says so, kindly.
            let n = (model.turns.compactMap(\.number).max() ?? 1) + 1
            let text = op["text"] as? String ?? ""
            Task {
                emit(["event": "turn_started", "turn": n, "input": text])
                emit(["event": "item_started", "id": "m\(n)", "kind": ["type": "message"]])
                await stream("This is a recorded session, so I can't act on that here. Connect to frog on your Mac and I'll get right on it.", id: "m\(n)", type: "text")
                emit(["event": "item_completed", "id": "m\(n)", "item": ["type": "message", "text": "This is a recorded session, so I can't act on that here. Connect to frog on your Mac and I'll get right on it."]])
                emit(["event": "turn_ended", "turn": n, "reason": ["type": "complete"],
                      "usage": ["input_tokens": 120, "output_tokens": 30, "model_calls": 1]])
                emit(["event": "idle"])
            }
        default:
            break
        }
    }

    private func finish(_ reason: EndReason) {
        guard let n = model.turns.last?.number else { return }
        let type = reason == .denied ? "denied" : "cancelled"
        emit(["event": "turn_ended", "turn": n, "reason": ["type": type],
              "usage": ["input_tokens": 0, "output_tokens": 0, "model_calls": 0]])
        emit(["event": "idle"])
    }

    private func emit(_ event: [String: Any]) {
        seq += 1
        var env = event
        env["seq"] = seq
        env["session"] = model.id
        env["created"] = Int64(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let e = try? JSONDecoder.frog.decode(Envelope.self, from: data) else { return }
        model.apply(e)
    }
}

/// A link that goes nowhere, until the real one is attached.
@MainActor
final class DeadLink: SessionLink {
    static let shared = DeadLink()
    func send(op: [String: Any], in session: String) {}
}

extension EndReason: Equatable {
    public static func == (a: EndReason, b: EndReason) -> Bool {
        switch (a, b) {
        case (.complete, .complete), (.maxTokens, .maxTokens), (.denied, .denied), (.looping, .looping),
             (.stepLimit, .stepLimit), (.cancelled, .cancelled), (.error, .error): true
        default: false
        }
    }
}
