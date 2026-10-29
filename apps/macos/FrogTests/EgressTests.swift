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

    func testAgentStartedSessionsAreWorkers() {
        let req = SessionBroker.StartRequest(title: "w", prompt: "p", cwd: nil, model: nil, mode: nil, worktree: false)
        XCTAssertTrue(SessionBroker.engineFlags(req: req, parent: nil).contains("--worker"))
    }
}
