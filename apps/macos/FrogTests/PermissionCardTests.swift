import XCTest
@testable import Frog

/// A step that starts waiting on you shows its permission card. The running turn's segments are
/// cached (`FlowCache`) with copies of the items; the cache's signature missed `needsPermission`,
/// so the group kept the step as it was before the request and the card never drew (the parity
/// page's Mac half: "Needs you", no "Can I bash this?").
@MainActor
final class PermissionCardTests: XCTestCase {
    private var seq: UInt64 = 0
    private func send(_ c: Conversation, _ event: String) {
        seq += 1
        let line = #"{"seq":\#(seq),"session":"s","created":1790113417019,"event":\#(event)}"#
        c.ingest(try! JSONDecoder.frog.decode(Envelope.self, from: Data(line.utf8)))
    }

    func testAWaitingStepRebuildsItsGroup() {
        let c = Conversation(folder: URL(fileURLWithPath: "/tmp/demo"), link: nil, replay: false, session: "s")
        let flows = FlowCache()
        send(c, #""turn_started","turn":1,"input":"hi""#)
        send(c, #""item_started","id":"t5","kind":{"type":"tool_call","name":"Bash","arg":"cargo test"}"#)
        _ = flows.segments(of: c.turns[0], showThinking: true)
        send(c, #""permission_request","id":"p1","item":"t5","name":"Bash","arg":"cargo test","always":"always allow `cargo`""#)
        guard case .activity(let g)? = flows.segments(of: c.turns[0], showThinking: true).last else {
            return XCTFail("no activity group")
        }
        XCTAssertTrue(g.steps.contains { $0.id == "t5" && $0.needsPermission })
    }
}
