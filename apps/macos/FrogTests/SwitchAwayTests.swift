import Foundation
import Network
import XCTest
@testable import Frog

/// Cam's bug: start a new thread, switch away while its first answer is on its way, and the
/// turn reads "Interrupted" with nothing streamed. A real engine (the bundled `frog --serve`),
/// a stand-in model that holds the first answer until the test lets it go, and a scratch HOME,
/// so the session log is the engine's own. Switching away must never stop a turn in flight.
@MainActor
final class SwitchAwayTests: XCTestCase {
    private var home: URL!
    private var model: HeldModel!
    private var defaults: [String: Any?] = [:]
    private let prompt = "switch-away probe: say done"

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appending(path: "frog-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        model = try await HeldModel.start(marker: "switch-away probe")
        Frog.overrides = [
            "HOME": home.path,
            "FROG_BASE_URL": "http://127.0.0.1:\(model.port)/v1",
            "FROG_API_KEY": "test",
            "FROG_KEYCHAIN": "off",
        ]
        for key in ["newMessageModelPolicy", "defaultModel"] {
            defaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set("fixed", forKey: "newMessageModelPolicy")
        UserDefaults.standard.set("cloud/qwen3-coder-next", forKey: "defaultModel")
    }

    override func tearDown() async throws {
        model.stop()
        Frog.overrides = [:]
        for (key, value) in defaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: home)
        Library.shared.refresh()
    }

    private func folder(_ name: String) throws -> URL {
        let url = home.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func log(_ id: String?) -> String {
        guard let id else { return "" }
        let url = home.appending(path: ".local/share/frog/sessions/\(id).jsonl")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func wait(_ limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// One line of the timeline: what the switched-away thread looks like at `t`.
    private func probe(_ c: Conversation, _ t: String) -> String {
        let running = (c.link as? EngineProcess)?.isRunning == true
        let id = c.sessionID
        let started = c.turns.last?.number != nil
        let log = log(id)
        let line = "t=\(t) engine=\(running ? "alive" : "DEAD") stopping=\(!c.isLive) session=\(id ?? "-") "
            + "turnStarted=\(started) jsonl=\(log.isEmpty ? "none" : "\(log.split(separator: "\n").count) lines") "
            + "ended=\(log.contains("\"turn_ended\"") ? (log.contains("\"cancelled\"") ? "CANCELLED" : "complete") : "no")"
        print("SWITCH-TIMELINE \(line)")
        return line
    }

    enum Switch { case otherFolder, sameFolder }

    /// A new thread in a pane, its first message sent at once; switched away at `after`.
    private func run(switchAt after: Duration, _ how: Switch) async throws {
        let a = try folder("home"), b = try folder("elsewhere")
        let panes = Panes(Workspace(folder: a, fresh: true))
        let pane = panes.items[0]
        let thread = try XCTUnwrap(pane.workspace.conversation)
        thread.submit(prompt)
        var timeline = [probe(thread, "0")]

        try await Task.sleep(for: after)
        timeline.append(probe(thread, "\(after) before switch"))
        switch how {
        case .otherFolder: panes.switchFolder(b, in: pane)
        case .sameFolder: pane.workspace.newSession()
        }
        XCTAssertFalse(pane.workspace.conversation === thread, "switched away")
        try await Task.sleep(for: .milliseconds(1500))
        timeline.append(probe(thread, "switch+1.5s"))
        let alive = (thread.link as? EngineProcess)?.isRunning == true
        XCTAssertTrue(alive, "the engine outlived the switch\n" + timeline.joined(separator: "\n"))
        XCTAssertTrue(thread.isLive, "nothing asked it to stop")

        // The first answer arrives now: the turn finishes off screen.
        model.release()
        await wait(.seconds(20)) { log(thread.sessionID).contains("\"turn_ended\"") }
        timeline.append(probe(thread, "released"))
        let text = log(thread.sessionID)
        XCTAssertFalse(text.isEmpty, "the thread's session log exists\n" + timeline.joined(separator: "\n"))
        XCTAssertTrue(text.contains("\"turn_ended\""), "its turn ended\n" + timeline.joined(separator: "\n"))
        XCTAssertFalse(text.contains("\"cancelled\""), "and wasn't cancelled\n" + timeline.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(model.answered, 1)

        // Back to it: the pane picks up the same engine.
        let id = try XCTUnwrap(thread.sessionID)
        let info = SessionInfo(id: id, modified: 0, created: 0, model: "m", firstInput: nil, title: nil,
                               end: nil, forkedFrom: nil, cwd: a.path)
        panes.open(info, in: pane, window: nil)
        await wait(.seconds(3)) { pane.workspace.conversation === thread }
        XCTAssertTrue(pane.workspace.conversation === thread, "reopened on the engine that kept running")
        panes.stopAll()
        thread.stop(reason: "test over")
        if let id = thread.sessionID { _ = SessionBroker.shared.adopt(id) }
        await wait(.seconds(3)) { (thread.link as? EngineProcess)?.isRunning != true }
    }

    /// Before its engine has said which session it is: held until it does.
    func testSwitchingFoldersAtOnce() async throws { try await run(switchAt: .zero, .otherFolder) }
    func testSwitchingFoldersHalfASecondIn() async throws { try await run(switchAt: .milliseconds(500), .otherFolder) }
    func testSwitchingFoldersTwoSecondsIn() async throws { try await run(switchAt: .seconds(2), .otherFolder) }
    func testSwitchingFoldersFiveSecondsIn() async throws { try await run(switchAt: .seconds(5), .otherFolder) }
    func testNewThreadInTheSameFolderTwoSecondsIn() async throws { try await run(switchAt: .seconds(2), .sameFolder) }
}

/// A chat-completions endpoint that holds requests carrying `marker` until `release()`, then
/// answers each with a one-word streamed reply. Anything else is answered at once.
final class HeldModel: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "held-model")
    private let marker: String
    private var held: [NWConnection] = []
    private var released = false
    private(set) var port: UInt16 = 0
    private(set) var answered = 0

    private init(marker: String) throws {
        self.marker = marker
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(marker: String) async throws -> HeldModel {
        let m = try HeldModel(marker: marker)
        m.listener.newConnectionHandler = { [weak m] c in m?.accept(c) }
        m.listener.start(queue: m.queue)
        for _ in 0..<250 {
            if let p = m.listener.port?.rawValue, p != 0 { m.port = p; return m }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "HeldModel", code: 1)
    }

    func stop() {
        queue.sync {
            held.forEach { $0.cancel() }
            held = []
        }
        listener.cancel()
    }

    func release() {
        queue.sync {
            released = true
            let waiting = held
            held = []
            waiting.forEach(answer)
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
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
            self.route(c, head: head, body: String(decoding: body, as: UTF8.self))
        }
    }

    private func route(_ c: NWConnection, head: String, body: String) {
        guard head.contains("chat/completions") else {
            send(c, "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
            return
        }
        if body.contains(marker), !released {
            held.append(c)
            return
        }
        answer(c)
    }

    private func answer(_ c: NWConnection) {
        answered += 1
        let chunks = [
            #"{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"done"},"finish_reason":null}]}"#,
            #"{"id":"x","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"id":"x","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}"#,
            "[DONE]",
        ]
        send(c, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
             + chunks.map { "data: \($0)\n\n" }.joined())
    }

    private func send(_ c: NWConnection, _ text: String) {
        c.send(content: Data(text.utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
