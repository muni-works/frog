import Foundation
import Network
import XCTest
@testable import Frog

/// The real bundled engine (`frog --serve`, started by the app as it always is) in a scratch
/// HOME, talking to a scripted model: a flow test writes the turn it wants and the engine does
/// the rest (permission cards, questions, subagents, file edits, errors) exactly as it does for
/// a real model. This extends `SwitchAwayTests`' stand-in (HeldModel) into a script.
///
///     let engine = try await ScriptedEngine.start()
///     engine.model.script(
///         .reply(.tool("Bash", ["command": "touch made-by-frog"])),   // the first request
///         .after("made-by-frog", .text("Done."))                       // once the tool ran
///     )
///
/// Each step answers the first model request that comes after the step before it and whose
/// newest message contains its `after` text (any request, when it has none). Requests no step
/// claims get "ok". A subagent's requests come here too, so a step can be the child's.
@MainActor
final class ScriptedEngine {
    let home: URL
    /// The project the flow works in: a git repository with one commit.
    let folder: URL
    let model: ScriptedModel
    private var saved: [String: Any?] = [:]

    /// - Parameters:
    ///   - mode: the permission mode new sessions start in (Settings' `defaultMode`); `default`
    ///     asks before every risky step.
    ///   - config: extra lines for the engine's config.toml (`child_quiet_secs = 2`).
    ///   - sharedHome: the engine uses the test host's own HOME, so its sessions are the ones the
    ///     app lists (the sidebar, rename, delete); the config and sessions it adds are removed.
    static func start(mode: Mode = .default, config: [String] = [], git: Bool = true, sharedHome: Bool = false) async throws -> ScriptedEngine {
        let model = try await ScriptedModel.start()
        return try ScriptedEngine(model: model, mode: mode, config: config, git: git, sharedHome: sharedHome)
    }

    /// `start`, for a synchronous setUp: pumps the run loop until the model listens.
    static func startNow(mode: Mode = .default, config: [String] = [], git: Bool = true, sharedHome: Bool = false) throws -> ScriptedEngine {
        var result: Result<ScriptedEngine, Error>?
        Task { @MainActor in
            do { result = .success(try await start(mode: mode, config: config, git: git, sharedHome: sharedHome)) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(10)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        guard let result else { throw NSError(domain: "ScriptedEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "the model never listened"]) }
        return try result.get()
    }

    private let shared: Bool
    private var sessionsBefore: Set<String> = []

    private init(model: ScriptedModel, mode: Mode, config: [String], git: Bool, sharedHome: Bool) throws {
        self.model = model
        shared = sharedHome
        let scratch = FileManager.default.temporaryDirectory.appending(path: "frog-flow-\(UUID().uuidString.prefix(8))")
        home = sharedHome ? URL(fileURLWithPath: NSHomeDirectory()) : scratch
        folder = scratch.appending(path: "project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let conf = home.appending(path: ".config/frog")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        // The model's own quiet question would interrupt a held reply: off unless asked for.
        let lines = ["call_quiet_secs = 0"] + config
        try lines.joined(separator: "\n").write(to: conf.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        sessionsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? [])
        if git {
            try "hello\n".write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
            try Self.git(["init", "-q", "-b", "main"], in: folder)
            try Self.git(["add", "."], in: folder)
            try Self.git(["-c", "user.name=Flow", "-c", "user.email=flow@example.invalid", "commit", "-q", "-m", "start"], in: folder)
        }
        Frog.overrides = [
            "HOME": home.path,
            "FROG_BASE_URL": "http://127.0.0.1:\(model.port)/v1",
            "FROG_API_KEY": "test",
            "FROG_KEYCHAIN": "off",
            "GIT_AUTHOR_NAME": "Flow", "GIT_AUTHOR_EMAIL": "flow@example.invalid",
            "GIT_COMMITTER_NAME": "Flow", "GIT_COMMITTER_EMAIL": "flow@example.invalid",
        ]
        for key in ["newMessageModelPolicy", "defaultModel", "defaultMode"] {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set("fixed", forKey: "newMessageModelPolicy")
        UserDefaults.standard.set("cloud/qwen3-coder-next", forKey: "defaultModel")
        UserDefaults.standard.set(mode.rawValue, forKey: "defaultMode")
    }

    var sessionsDir: URL { home.appending(path: ".local/share/frog/sessions") }

    func stop() {
        model.stop()
        Frog.overrides = [:]
        if shared {
            try? FileManager.default.removeItem(at: home.appending(path: ".config/frog/config.toml"))
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)) ?? [])
            for name in now.subtracting(sessionsBefore) { try? FileManager.default.removeItem(at: sessionsDir.appending(path: name)) }
        }
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if !shared { try? FileManager.default.removeItem(at: home) }
    }

    /// The session's log, as the engine wrote it.
    func log(_ session: String?) -> String {
        guard let session else { return "" }
        return (try? String(contentsOf: sessionsDir.appending(path: "\(session).jsonl"), encoding: .utf8)) ?? ""
    }

    func file(_ name: String) -> String? { try? String(contentsOf: folder.appending(path: name), encoding: .utf8) }

    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationStatus != 0 { throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text]) }
        return text
    }
}

/// An OpenAI-compatible chat-completions endpoint that answers from a script.
final class ScriptedModel: @unchecked Sendable {
    enum Reply {
        /// Streamed text, then stop.
        case text(String)
        /// One tool call (name and arguments), then stop for tool calls.
        case tool(String, [String: Any])
        /// Never answers: the request stays open until the test releases it or stops the model.
        case silent
        /// Held until `release()`, then the text.
        case held(String)
        /// An HTTP error with this status and message.
        case error(Int, String)
    }

    struct Step {
        var after: String?
        var reply: Reply
        /// Only a request whose newest message is a tool's result.
        var toolResult = false
        static func reply(_ r: Reply) -> Step { Step(after: nil, reply: r) }
        static func after(_ text: String, _ r: Reply) -> Step { Step(after: text, reply: r) }
        /// The model's next call once a tool has run (its result is the newest message).
        static func afterTool(_ r: Reply) -> Step { Step(after: nil, reply: r, toolResult: true) }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "scripted-model")
    private var steps: [Step] = []
    private var held: [(NWConnection, String)] = []
    private var silent: [NWConnection] = []
    private var _requests: [String] = []
    private(set) var port: UInt16 = 0

    /// The newest message of each request, in order.
    var requests: [String] { queue.sync { _requests } }

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() async throws -> ScriptedModel {
        let m = try ScriptedModel()
        m.listener.newConnectionHandler = { [weak m] c in m?.accept(c) }
        m.listener.start(queue: m.queue)
        for _ in 0..<250 {
            if let p = m.listener.port?.rawValue, p != 0 { m.port = p; return m }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ScriptedModel", code: 1)
    }

    func script(_ steps: Step...) { queue.sync { self.steps = steps } }
    func add(_ steps: Step...) { queue.sync { self.steps += steps } }

    /// Answers every held request.
    func release() {
        queue.sync {
            let waiting = held
            held = []
            waiting.forEach { answer($0.0, .text($0.1)) }
        }
    }

    func stop() {
        queue.sync {
            (held.map(\.0) + silent).forEach { $0.cancel() }
            held = []
            silent = []
        }
        listener.cancel()
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { c.cancel() } else { self.read(c, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            if body.count < length, !done, error == nil { return self.read(c, buffer) }
            self.route(c, head: head, body: Data(body))
        }
    }

    private static func newestRole(_ body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return "" }
        return messages.last?["role"] as? String ?? ""
    }

    /// The newest message's text (a user prompt or a tool result).
    private static func newest(_ body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]], let last = messages.last else { return "" }
        if let s = last["content"] as? String { return s }
        if let parts = last["content"] as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    private func route(_ c: NWConnection, head: String, body: Data) {
        guard head.contains("chat/completions") else {
            return send(c, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        }
        // Side jobs (titles, summaries) aren't streamed turns: answer them plainly.
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let message = Self.newest(body)
        _requests.append(message)
        if json["tools"] == nil {
            return answer(c, .text("Flow title"))
        }
        let role = Self.newestRole(body)
        guard let i = steps.firstIndex(where: { ($0.after.map { message.contains($0) } ?? true) && (!$0.toolResult || role == "tool") }) else {
            return answer(c, .text("ok"))
        }
        let step = steps.remove(at: i)
        answer(c, step.reply)
    }

    private func answer(_ c: NWConnection, _ reply: Reply) {
        func chunk(_ delta: [String: Any], finish: String? = nil) -> String {
            let choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish ?? NSNull()]
            let obj: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "choices": [choice]]
            return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        }
        let usage = #"{"id":"x","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}"#
        var chunks: [String]
        switch reply {
        case .text(let text):
            chunks = [chunk(["role": "assistant", "content": text]), chunk([:], finish: "stop")]
        case .tool(let name, let args):
            let a = String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let call: [String: Any] = ["index": 0, "id": "call_\(UUID().uuidString.prefix(8))", "type": "function",
                                       "function": ["name": name, "arguments": a]]
            chunks = [chunk(["role": "assistant", "tool_calls": [call]]), chunk([:], finish: "tool_calls")]
        case .silent:
            silent.append(c)
            return
        case .held(let text):
            held.append((c, text))
            return
        case .error(let status, let message):
            let body = #"{"error":{"message":"\#(message)","type":"test"}}"#
            return send(c, "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        }
        chunks += [usage, "[DONE]"]
        send(c, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
             + chunks.map { "data: \($0)\n\n" }.joined())
    }

    private func send(_ c: NWConnection, _ text: String) {
        c.send(content: Data(text.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
